## Slice 58: Seeded Procedural World Generation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 57](slice-57.md), [Slice 61](slice-61.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 49 (`WorldBuildConfig.seed` set from
`seed.derive(.worldgen_procedural)`; `SeedDomain`), Slice 33 (landed; archetype
IDs for spawn tables), Slice 57 (`ItemId` and `worldItemTemplate` for resource
yields), and Slice 61 (`ResourceNodeKindCatalog` and `resourceNodeTemplate` for
node placement). Slice 38, once it lands, rebinds strata depth to
`levelElevation`. Slice 62 extends this slice's spec with spawn anchors and
consumes `chunk_biomes`. Slice 65C streams generation on the lane when it
has a thread; the threaded main-thread path remains the no-thread fallback and
the `initProceduralFromSpec` contract (no Slice 51 dependency here; see
"Worldgen off the main thread").

Goal: replace the hard-coded procedural generator with a data-authored one
(biomes, terrain palettes, surface features, resource nodes, underground strata
and resource veins, spawn tables). The world must be a pure function of
`WorldBuildConfig.seed`, the spec, and the world dimensions, computed through
`src/core/rng.zig` with integer-only math. Chunked generation must fit
`WorldSystem` levels/chunks and the existing nav and perception builds. The
same seed must produce the same golden hash on serial and threaded builds and on
Debug and ReleaseFast.

**Decision: load-time only, no streaming.** The reasons:

- `WorldSystem` dimensions and the level stack are fixed when the world is
  built.
- `addDenseLayer` refuses layers after the GPU tile buffer is uploaded
  (`world_system.zig:1636`).
- The nav graph and perception caches build once at pipeline init
  (`simulation_pipeline.zig:650,674-676`).

Streaming would mean chunk residency, partial GPU uploads, and incremental nav
graph insertion, which is a separate redesign. World size stays bounded by the
existing fixed refusals (`k_max_dense_submit_stack_cap`,
`k_max_dense_tile_gpu_bytes`). Generation cost is load-time work on that
already-bounded world, not a per-step budget.

### Current foundation (do not rebuild)

Current generator:

- `WorldBuildConfig` (`src/game/world_system.zig:137-148`) has a literal
  `seed` default at `:141` and a configurable `chunk_size_tiles` (default 16)
  at `:140`. Slice 49 keeps `seed` and has `LoadingState` set it to
  `session_seed.derive(.worldgen_procedural)`.
- `initProcedural` / `initProceduralFromMeta` (`:440-508`) build the surface
  floor with the threaded per-chunk `buildProceduralChunk` (`:2148-2174`) over
  the hard-coded `proceduralGroundTile` rules (`:2176-2193`), then call the
  serial `addProceduralSparseTiles` (`:2122-2145`).
- The private `hash2` (`:2258-2269`) is not `rng.zig`.

World building blocks:

- Underground levels come from `addUndergroundLevelStack`, a uniform
  `dirt`/`dirt_dark` fill (`:1676-1689`).
- `DenseLayerRow.uniform_fill_tile` (`:225-232`) drives the nav and
  perception memset fast paths (`systems/pathfinding/nav_grid.zig:278-301`,
  `systems/perception.zig:824,1193`). Today a layer takes the fast path only
  when it is truly uniform: non-blocking → skip, blocking → memset blocked;
  any mixed layer goes per-cell.
- Reused helpers: `addDenseLayer` (`:1635-1669`), `addSparseTile` (`:1699`),
  `setDenseTile`, `requireTileByName` (`:1959`), `chunksX` / `chunksY`
  (`:2109-2116`), `validateDenseRenderBudget` (`:664`), and threaded chunk
  dispatch via `parallelForWithOptions` (`:497-501`).

Callers and demo spawning:

- `LoadingState.loadGameDemo` (`src/game/loading_state.zig:186-214`) calls
  `GameDemoState.initProceduralWithRuntimeAssets`
  (`src/game/game_demo_state.zig:323-357`) with `default_world_build_config`
  (`:198-206`: 256×256, 31 underground levels).
- Spawns are hard-coded grids: `spawnTestSquares` (`:698-784`),
  `undergroundSpawnLevelForIndex` / `carveUndergroundSpawnPocket`
  (`:860-884`), plus fixed obstacles and interest markers (`:889-909`).

Content and test rules:

- Tileset: 224 named tiles with `walkable` / `blocks_movement` / `blocks_vision`
  flags (`assets/sprites/world_tileset.json`); strict loader
  `src/assets/world_tileset_meta.zig`.
- Unit tests may call procedural entry points only at 16×16 or smaller with at
  most 1 underground level (`docs/coding-standards.md:414-427`). The loading
  test config is 8×8 (`loading_state.zig:242-247`).

### Architecture notes

**Modules.**

- `src/game/worldgen.zig` is the front.
- `src/game/worldgen/spec.zig`: JSON → validated `WorldGenSpec`.
- `src/game/worldgen/generate.zig`: chunk jobs and the main-thread commit.
- `src/game/worldgen/spawns.zig`: candidate ranking.
- `src/core/noise.zig`: new integer value noise, a named primitive owned by
  `core` and built on `rng.mix64`.
- `WorldSystem.initProceduralFromSpec` replaces `initProceduralFromMeta`'s
  body. Delete `ProceduralTiles`, `ProceduralBuildContext`,
  `buildProceduralChunk`, `proceduralGroundTile`, `addProceduralSparseTiles`,
  and `hash2` in the same change.
- `initDemo*` and the test paths stay unchanged.

**Seed.**

- `WorldBuildConfig.seed` stays: it is Slice 49's plain worldgen input, and
  benches/tools set it directly. `LoadingState` already sets it to
  `session_seed.derive(.worldgen_procedural)` (Slice 49).
  `initProceduralFromSpec` uses `config.seed` as `world_seed`. This slice adds
  no new `LoadingState` seed code and no worldgen `SeedDomain` tag.
- Each field gets its own seed, an internal derivation of `config.seed` (not a
  domain): `rng.mix64(world_seed, 0, 0, field_salt)` for elevation, moisture,
  palette, feature, node, vein, stratum, and spawn.
- Every per-cell draw is `rng.mix64(field_seed, cell_index_u32, level_u32, salt)`.
  It is a pure function with no generator state and no dependence on order.

**Integer-only math, so golden hashes are bit-exact across optimize modes and
targets.**

- `noise.valueNoise2(seed, x, y, cell_size, octaves) u16`:
  - Lattice value = top 16 bits of
    `rng.mix64(seed, lx | (ly << 16), octave, noise_lattice_salt)`. World
    dimensions are `u16`, so the packed lattice fits.
  - Q16 bilinear interpolation with an integer smoothstep:
    `t*t*(3·2^16 - 2t) >> 32`, computed in `u64`.
  - Octaves are summed at amplitude `2^-o` and renormalized to `0..65535`.
- No f32 anywhere in generation.
- JSON thresholds and densities in `[0, 1]` convert once at load to `u16`
  fixed point.

**Spec: `assets/world/worldgen.json`, strict (`ignore_unknown_fields = false`).**

```json
{ "version": 1,
  "noise": { "elevation": { "cell_size": 32, "octaves": 3 },
             "moisture":  { "cell_size": 48, "octaves": 2 } },
  "biomes": [
    { "id": "lake", "elevation_max": 0.30, "palette": [ { "tile": "water_1", "weight": 1 } ],
      "edge_tile": "water_shore_0" },
    { "id": "forest", "moisture_min": 0.55, "elevation_min": 0.40,
      "palette": [ { "tile": "grass", "weight": 6 }, { "tile": "grass_rocky", "weight": 1 } ],
      "features": [ { "tile": "tree_0", "density": 0.35 } ],
      "nodes": [ { "kind": "berry_bush", "density": 0.02 } ],
      "spawns": [ { "archetype": "timid", "density": 0.25 }, { "archetype": "aggressive", "density": 0.10 } ] },
    { "id": "plains", "default": true,
      "palette": [ { "tile": "grass", "weight": 8 }, { "tile": "grass_patchy", "weight": 2 }, { "tile": "stone_floor", "weight": 1 } ],
      "features": [ { "tile": "deco_0", "density": 0.04 }, { "tile": "tree_0", "density": 0.05 } ],
      "spawns": [ { "archetype": "wanderer", "density": 0.3 }, { "archetype": "curious", "density": 0.15 } ] } ],
  "strata": [
    { "depth_min": 1, "depth_max": 31, "fill": [ "dirt", "dirt_dark" ],
      "veins": [ { "tile": "gravel", "cell_size": 6, "threshold": 0.80 } ],
      "spawns": [ { "archetype": "aggressive", "density": 0.05 } ] } ],
  "resources": [ { "tile": "gravel", "item": "iron_ore", "min": 1, "max": 3 } ] }
```

- Biomes are ordered and the first match wins. Each biome has optional
  `elevation_min` / `_max` and `moisture_min` / `_max`. Exactly one biome has
  `"default": true`, and it must be last.
- `edge_tile` is optional. It applies to cells whose 4-neighbour biome differs.
  A neighbor's biome is recomputed from the same pure function, never read from
  another job's output, so chunks stay independent.
- `nodes` is optional. Each `kind` resolves against Slice 61's
  `ResourceNodeKindCatalog` at load.
- Strata are indexed by depth below the surface: the level index today,
  `-levelElevation` after Slice 38. A stratum's `fill` cycles by depth.
- Load-time validation rejects loudly with no partial result:
  - unknown keys, `version != 1`, unknown tile / archetype / item / node-kind
    names
  - a missing or non-final default biome
  - thresholds outside `[0, 1]`, or a biome whose feature densities plus node
    densities sum above 1 (they share one candidate per block)
  - surface palette or feature tiles with no tileset entry
  - **strata `fill` / `veins` tiles that do not `blocks_movement`.** Underground
    stays solid until dug, which preserves dig semantics and the nav fast path.
  - overlapping strata or `depth_max > 65535`
  - `resources` `min > max` or above the item's `max_stack`
  - any cap below exceeded
- Generate-time refusals (no partial result):
  - a world deeper than the authored strata: `error.WorldGenStratumMissing`
  - `config.chunk_size_tiles % feature_block_cells != 0`:
    `error.WorldGenChunkFeatureMisaligned`. Feature/node blocks must not
    straddle chunks, or the "features are chunk-local" rule below breaks.

**Fixed caps and budgets.** All are fixed constants, independent of world size.
None is a working data-structure capacity; the classification and the
world-sized working capacities follow the table.

| Constant | Value |
| --- | --- |
| `max_worldgen_biomes` | 32 |
| `max_palette_entries` | 16 |
| `max_features_per_biome` | 8 |
| `max_node_rules_per_biome` | 8 |
| `max_spawn_rules` (per biome or stratum) | 8 |
| `max_strata` | 16 |
| `max_veins_per_stratum` | 4 |
| `max_tile_yields` | 32 |
| `max_noise_octaves` | 4 |
| noise `cell_size` | `4..=256` |
| `feature_block_cells` | 4 (one jittered feature-or-node candidate per 4×4 block) |
| `spawn_candidates_per_chunk` | 4 (per level-chunk) |
| `max_worldgen_resource_nodes` | 2048 (Slice 61's world-sized `resource_node_capacity` counts the nodes generation actually places) |
| `player_spawn_search_radius_cells` | 32 |

- The spawn **population cap** is caller-provided and fixed by game config
  (`battle_scale_demo_mover_count`). It is never derived from world size. A
  bigger world produces more candidates, not more spawns.
  `max_worldgen_resource_nodes` is the same kind of per-step-cost population
  budget; the node store itself is a world-sized capacity (Slice 61).
- **Classification (CLAUDE.md budgets / capacities / thresholds).**
  - Entity-population budgets: the population cap and
    `max_worldgen_resource_nodes`. Every spawn and node is a live entity with
    per-step cost (AI and steering for spawns; a static collision proxy and
    steering obstacle for nodes, until Slice 71B.2 moves grid statics out of
    the SAP), so a world-sized count would make per-step work scale with the
    map. Hash-ranked truncation is the deterministic degradation.
  - Per-cell / per-query work budgets: `max_noise_octaves`, noise
    `cell_size`, `player_spawn_search_radius_cells`.
  - Layout constants: `feature_block_cells` and `spawn_candidates_per_chunk`
    (per-job slot counts baked into the striped arena).
  - Inline spec-table ceilings that fail loudly at load: biomes (`BiomeId` is
    a `u8` with `0xFF` reserved, and Slice 69B copies `[max_worldgen_biomes]u8`
    lookups by value), and the palette, feature, node, spawn, strata, vein,
    and yield tables, kept inline so jobs read one flat validated value.
- **Working capacities are sized from the world at load, never fixed:** the
  striped arena (`jobs × per-job slots`, `jobs = level_count ×
  chunk_count`), `chunk_biomes` (surface chunk count), dense layers
  (`levels × cells`, under the loud `k_max_dense_tile_gpu_bytes` load-time
  ceiling), sparse feature tiles (the committed feature count, summed from
  `JobSummary.feature_count`), and the survivor lists (`min(candidates,
  cap)`). All are load-time allocations; nothing grows after load.
- **Per-query cost must not read a world-sized sparse count.** Surface
  features make level 0's sparse count scale with world area.
  `WorldSystem.levelBlocksMovement` today scans the level's whole sparse list
  (`sparseTileIndicesForLevel`) and every dense layer of every level, and it
  runs per cell in a dig's nav remask (`navCellBlockedFromSources`) and per
  walk sample in `world_gate`. This slice makes it read only the queried
  cell's chunk list (`sparseTileIndicesForChunk(level,
  localChunkIndexForCell(x, y))`) and only that level's dense bands (a
  per-level dense-layer index built by `addDenseLayer`, at most
  `max_dense_bands_per_level` entries per level, sized from the loaded
  levels). Each query then costs one chunk's tiles plus one level's bands on
  any world size.

**Generation, inside `WorldSystem.initProceduralFromSpec`.** It returns
`GeneratedWorld { world, spawns: GeneratedSpawns, nodes: GeneratedNodes,
player_spawn: CellCoord }`.

1. Main thread setup:
   - `buildCatalog`.
   - Validate `chunk_size_tiles % feature_block_cells == 0`.
   - Surface level plus its floor layer, then one floor layer per underground
     level filled with that stratum's first fill tile, using the existing
     `addLevel` / `addDenseLayer`.
   - Reserve per-job output slots before dispatch: `jobs × max feature/node
     candidates`, `jobs × spawn_candidates_per_chunk`, and a `jobs ×
     JobSummary` array `{feature_count, node_count, spawn_count, all_blocking,
     none_blocking, center_biome}`. This is a striped arena (documented MAL
     exception), sized from the same `level_count × chunk_count` the dispatch
     uses.
2. One threaded job per `(level, chunk)` (`items_per_range = 1`, with asserts
   on the cell write bound and `range.index`):
   - Writes that chunk's cells into its level's dense-layer slice. Chunks write
     disjoint cell ranges.
   - Surface: classify the biome per cell, pick the palette tile weighted by
     `rng.boundedU32`, apply the edge tile, and draw one jittered candidate per
     4×4 block on non-blocking terrain. One density draw picks a feature, a
     resource node, or nothing (cumulative: the biome's features, then its
     nodes). Emit spawn candidates; they skip blocking terrain and this job's
     own feature and node cells. Features and nodes are chunk-local (blocks
     never straddle chunks, validated above), so the check needs no cross-job
     read. Records the biome at the chunk center in `center_biome`.
   - Underground: stratum fill by depth, veins by noise threshold, spawn
     candidates with `carve_pocket = true`.
   - Records `all_blocking` (every written cell `blocks_movement`) and
     `none_blocking` (no written cell `blocks_movement`) for the job.
3. Main thread commit, in level → chunk → slot order:
   - `addSparseTile` for each feature.
   - Per layer: `uniform_blocking = .blocking` if every job on the layer is
     `all_blocking`, `.open` if every job is `none_blocking`, otherwise
     `.mixed`. An AND of `all_blocking` alone would map a lake-plus-plains
     surface to "skip" and drop every water cell from nav and perception.
   - Clear `uniform_fill_tile` on any layer whose tile IDs vary.
   - Write `WorldSystem.chunk_biomes[chunk_index] = center_biome` for surface
     chunks.
4. Spawn and node selection:
   - If the spawn candidate count exceeds the population cap, keep the top N by
     `rng.mix64(spawn_seed, cell_index, level, spawn_rank_salt)`; ties break
     by level, then cell index.
   - If the node candidate count exceeds `max_worldgen_resource_nodes`, keep
     the top N by `rng.mix64(node_seed, cell_index, 0, node_rank_salt)`, with
     the same tie-break.
   - Sort the survivors by `(level, y, x)`. A fixed order means `EntityId`
     assignment is deterministic.
   - The sort and its allocation are load-time work.
5. Player spawn: deterministic ring search outward from the world center on
   level 0 for a walkable cell with no blocking sparse tile and no node, out to
   `player_spawn_search_radius_cells`. If none is found, the world is refused
   with `error.WorldGenNoWalkableSpawn`.
6. `rebuildChunks`, `tilemap_params`, and `validateDenseRenderBudget`, as
   today.

**Chunk biomes.** `WorldSystem.chunk_biomes: []u8` holds the biome id
(spec-order index; at most 32, fits `u8`) at each surface chunk's center,
written at commit. `chunkBiome(chunk_index) BiomeId` is the pure accessor, with
`BiomeId = enum(u8) { none = 0xFF, _ }`. Worlds not built by this generator
(`initDemo*`, tests) fill it with `.none`. Slice 62 (anchor biome filters) and
Slice 59's regional-weather gap consume it.

**Keep the nav/perception fast path.**

- `DenseLayerRow` gains `uniform_blocking: UniformBlocking = .mixed` with
  `UniformBlocking = enum(u2) { mixed, blocking, open }`. An enum (not
  `?bool`) so Slice 49's `StateHasher` folds it through the MAL.
- It is set in three places:
  - `addDenseLayer`, from the fill tile's flags (`.blocking` or `.open`)
  - the generator commit (above)
  - `setDenseTile` / `clearDenseTile`, which set it to `.mixed` when the new
    tile's `blocks_movement` differs from the layer value
- `WorldSystem.denseLayerUniformBlocking(layer) UniformBlocking` exposes it.
- `nav_grid.markWorldObstacles` (`:282`) and perception (`:824`, `:1193`)
  switch their fast-path test from `denseLayerUniformFillTile(...) != null` to
  this accessor: `.blocking` → memset blocked, `.open` → skip, `.mixed` →
  per-cell.
- Behavior is identical for today's uniform layers, veined strata keep the
  memset path, and mixed surfaces (water beside grass) stay per-cell exactly
  as today. Spawn-pocket carves set `.mixed`, just as carves already clear
  `uniform_fill_tile` today.

**Spawn adoption.** `GameDemoState.initProceduralWithRuntimeAssets`:

- Spawns from `GeneratedSpawns` through `archetype_catalog.bundleForId`.
  Underground records carve their pocket with the existing
  `carveUndergroundSpawnPocket`.
- Creates one resource node per `GeneratedNodes` record through Slice 61's
  `resourceNodeTemplate`, in the sorted order.
- Places the player at the center of `player_spawn`.
- Sizes `test_squares` to the actual record count, which is at most
  `battle_scale_demo_mover_count`. `deriveDemoPopulationCapacity` keeps the
  cap as its upper bound.
- Fixed demo obstacles skip blocking cells. Interest markers keep their fixed
  placement.
- `initDemo*` / `spawnTestSquares` stay unchanged, so existing parity tests
  are untouched.

**Resource yields (needs 57).**

- `spec.resources` builds a `TileYieldTable`, a fixed array of
  `[max_tile_yields]TileYield { tile, item, min, max, icon: AssetReference }`
  scanned linearly. `icon` is resolved against the `ItemCatalog` at spec load,
  because `DigController` holds no catalog. The table is copied into
  `DigConfig`, and the yield path passes the stored icon to Slice 57's
  `worldItemTemplate`, which takes a pre-resolved icon rather than the
  catalog.
- When `DigController.commit` (`src/game/dig_controller.zig`, run by the
  `dig_world_edit` stage after `admit` and the level-link seam) makes a
  successful dig edit and the old tile has a yield entry, it queues one
  `create_entity(worldItemTemplate(...))` at the dug cell center.
- Roll, keyed by `(cell_index, level)` so the same cell index on different
  levels rolls independently:

  ```
  yield_seed = seed.derive(.dig_yield)        // once, at SimulationPipeline.init
  cell_seed  = rng.mix64(yield_seed, cell_index, level, dig_yield_cell_salt)
  count      = min + rng.boundedU32(cell_seed, 0, step, dig_yield_salt, max - min + 1)
  ```

  This slice appends `SeedDomain.dig_yield = 5` (the value Slice 49
  reserves); `yield_seed` is passed into `DigConfig` at pipeline init.
- At most 1 yield per step (one dig per step). It obeys the Slice 57
  world-item cap rule and raises `world_item_creates_per_step_max` by 1;
  refusals are counted.
- `stageContract(.dig_world_edit)` adds a `structural_commands` write.
- Plane-traversal landing carves never yield; document this.

**Worldgen off the main thread.** Slice 65C streams generation on the lane
when it has a thread; the threaded main-thread path remains the no-thread
fallback and the `initProceduralFromSpec` contract. Background: Slice 50 makes
`parallelFor` from the
background-lane thread panic, so a lane job must call a serial generator path
(no `ThreadSystem`). This is worth doing only to keep a loading animation
responsive. Threaded generation on the main thread in `LoadingState` stays the
default and is what this slice ships. If adopted later, it is a cold
`GeneratedWorld` value handoff observed with Slice 51's `isDone`, not a
step-keyed consumer. Generation already honors the preconditions:

- Jobs read only immutable inputs: the validated spec, resolved `TileId` /
  `AiArchetypeId` / `ItemId` / node-kind values, dimensions, seed, and caps.
- Jobs write only buffers owned by the `WorldSystem` under construction.
- No `RuntimeAssets`, renderer, or SDL access happens during generation. The
  GPU upload stays lazy until first render.

**Determinism and save classification** (Slice 49 completeness lists, Slice 46
save sections, same change): `DenseLayerRow.uniform_blocking` is an enum hashed
through the dense-layer MAL; `WorldSystem.chunk_biomes` is hashed and saved.

**Diagnostics.** Use the `game` scoped logger at load only:

- info: seed, dimensions, levels, biome histogram size, feature count, node
  count, and `spawns_selected / candidates`
- one warn when the population cap or the node cap truncates candidates

Generation time goes through the existing `loading_build` perf timing. No
per-cell or per-step logging.

**Golden hashes.**

- Fixture: an inline test spec, independent of the shipped content, on a
  16×16 world with chunk size 8 and 1 underground level.
- Hash = an `rng.mix64` fold over all dense tiles (in layer order), each
  layer's `uniform_blocking`, sparse tiles `(level, x, y, tile, depth)`, node
  records, spawn records, `chunk_biomes`, and the player spawn.
- Three seeds are pinned to literal golden values.
- The shipped `assets/world/worldgen.json` gets a load + generate smoke test
  at the same size, with no golden value, so content tuning does not churn
  goldens.

**Resource interest markers (added by Slice 69).** Owner: Slice 58. Placement is
worldgen's job. Slice 61 already wires the `resource` kind
(`findNearestMarker(.resource)` in forage gather), and that needs no change.

- **Spec.** An optional top-level
  `"resource_markers": { "cell_tiles": 16, "min_nodes": 3, "radius": 128 }`.
  Validation: `cell_tiles` in `8..=64`, `min_nodes` in `1..=16`, `radius` in
  `(0, 512]`. When the key is absent, no markers are generated. The shipped
  `worldgen.json` sets it.
- **Cap.** `max_worldgen_interest_markers = 64` is the fixed cap on all
  generator-placed markers (Slice 69A's authored marker sockets fill first).
  It comes with `comptime assert(max_worldgen_interest_markers +
  demo_interest_marker_count <= interest_marker_capacity)`, that is
  64 + 4 ≤ 128. `demo_interest_marker_count` becomes a named
  `game_demo_state.zig` constant derived from `placeDemoInterestMarkers`'
  array length (`:894-899`). The remaining 60 slots stay for authored and
  later markers.
- **Algorithm.** It runs on the main thread at load, after step 4 (node
  selection), so it only ever marks surviving nodes.
  1. Key each surviving node record by `level << 32 | (y / cell_tiles) << 16 |
     (x / cell_tiles)`.
  2. Sort `(key, record index)` pairs in a load-time scratch buffer of at most
     `max_worldgen_resource_nodes = 2048` entries.
  3. Each run with at least `min_nodes` members becomes a candidate. Its
     anchor node is the member whose cell is nearest, by integer squared
     distance, to the floor of the run's integer centroid; ties go to the
     lowest (y, x).
  4. If the candidates exceed the remaining marker budget, keep them by member
     count descending, then `rng.mix64(node_seed, @truncate(key),
     @truncate(key >> 32), resource_marker_rank_salt)` ascending, then key.
  5. Sort the kept candidates by the anchor node's (level, y, x).
  6. Emit `GeneratedWorld.markers` records `{ kind = .resource, level, x, y =
     anchor node cell center, radius }`. The center is
     `(cell + 0.5) · world.tile_size` using the world's `tile_size`
     (`world_system.zig:283`, from tileset metadata), never a hard-coded 32.
     It is exact in f32 for the shipped 32 px tile and any power-of-two tile
     size.
  The marker sits on a real node, so forage's long-range attractor (query
  radius 400) always leads within node-query range (256) of a node.
- **Adoption.** `initProceduralWithRuntimeAssets` calls
  `world.addInterestMarker` for each record in order. A generated world no
  longer calls Slice 61's `placeDemoResourceNodes` or its single demo
  `resource` marker; both stay on the `initDemo*` path. A generated world's
  nodes and resource markers therefore come only from the generator.
- **Golden and save.** Markers fold into the golden hash after the player spawn
  as `(kind, level, x bits, y bits, radius bits)`, in the same change as
  Slice 58's pinned goldens, so no golden churns. Interest markers are already
  hashed and saved over live slots.
- **Slice 61 (no change, recorded for clarity):** forage gather keeps
  `InterestMarkerStore.findNearestMarker(.resource, ...)` with
  `interest_marker_query_radius = 400`. Worldgen markers need no new consumer
  code.

### Checklist

- [ ] `src/core/noise.zig`: integer value noise with tests for determinism,
      range, lattice continuity, and seed sensitivity.
- [ ] `worldgen/spec.zig`: strict loader and validation, every listed cap, and
      name resolution against the tileset, the archetype IDs, the
      `ItemCatalog`, and Slice 61's `ResourceNodeKindCatalog`. Ship
      `assets/world/worldgen.json` (lake, forest, and plains biomes with
      nodes, plus dirt strata with veins, tuned to roughly today's obstacle
      density) and confirm it installs.
- [ ] `worldgen/generate.zig` and `spawns.zig`: threaded per-(level, chunk)
      jobs, striped output slots, `JobSummary` with `all_blocking` and
      `none_blocking`, deterministic main-thread commit, hash-ranked
      population and node caps, sorted spawn and node order, player spawn
      search with refusal, chunk-alignment refusal.
- [ ] `WorldSystem.initProceduralFromSpec` (uses `config.seed`),
      `GeneratedWorld` with nodes, `chunk_biomes` + `chunkBiome`, and removal
      of the old generator and `hash2`. No new `LoadingState` seed code.
- [ ] `UniformBlocking` enum column and accessor; nav and perception fast-path
      migration; maintenance in `setDenseTile` / `clearDenseTile`.
- [ ] (capacity audit) `levelBlocksMovement` per-chunk sparse lookup and
      per-level dense-band index (Architecture notes). Tests (minimal
      fixtures): on a 2×1-chunk, 2-level world with sparse blockers in both
      chunks and two bands per level, every cell's result equals the previous
      whole-level scan; `world_gate` walk gates and a dig's nav remask give
      unchanged results; the per-level band index length equals the loaded
      level count.
- [ ] Slice 49 classification (`uniform_blocking` via the MAL, `chunk_biomes`
      hashed) and Slice 46 save section for `chunk_biomes`.
- [ ] `GameDemoState` adopts the generated spawns, nodes (through
      `resourceNodeTemplate`), and player spawn.
- [ ] `TileYieldTable` (with resolved `icon`) in `DigConfig`; `yield_seed =
      seed.derive(.dig_yield)` passed in at pipeline init; append
      `SeedDomain.dig_yield = 5`; `(cell_index, level)`-keyed roll; dig yield
      creates; `dig_world_edit` contract write; counters `dig_yields` /
      `dig_yields_refused`.
- [ ] Docs:
      - `docs/architecture.md`: worldgen ownership, load-time decision, seed
        flow (`WorldBuildConfig.seed` from Slice 49), main-thread generation.
      - `docs/atlas-asset-workflow.md` or `docs/development-workflow.md`:
        worldgen authoring and golden-update procedure.
      - `docs/simulation-tiers-and-pipeline.md`: dig yields.
- [ ] (added by Slice 69) Spec key `resource_markers` with validation, and
      `max_worldgen_interest_markers` plus its comptime assert against
      `interest_marker_capacity`. `demo_interest_marker_count` becomes a named
      constant.
- [ ] (added by Slice 69) Cluster selection after node selection: sort scratch, run walk, anchor
      node, hash-ranked truncation, sorted `GeneratedWorld.markers`.
      Adoption through `addInterestMarker`. Generated worlds skip
      `placeDemoResourceNodes` and its demo marker.
- [ ] (added by Slice 69) Golden fold includes markers. Tests:
      - a cluster at the threshold yields one marker on a member node;
      - a cluster below the threshold yields none;
      - candidates above the budget truncate to exactly the budget,
        identically across thread counts;
      - every marker coincides with a surviving node's cell center;
      - a spec without the key yields no markers.
- [ ] (added by Slice 69) Diagnostics: `info` with the marker count; one `warn` when the cap
      truncates.

### Acceptance checks

- [ ] Golden: the three pinned seeds match their literal hashes, and different
      seeds produce different hashes. The tests pass under both `zig build test`
      and `zig build test --release=fast` (integer-only math).
- [ ] Generating with `max_worker_threads = 0` and with N workers
      (`items_per_range = 1`, at least 2 ranges) gives the identical hash.
- [ ] Loader rejection tests: a non-blocking stratum tile, a missing or
      non-last default biome, an unknown tile/archetype/item/node kind, an
      exceeded cap, feature plus node density above 1, and threshold or depth
      range errors. Generate rejects `chunk_size_tiles = 6` with
      `feature_block_cells = 4`.
- [ ] Spawn and node caps: a candidate count above each cap selects exactly
      the cap. The selection is identical across thread counts. No spawn lands
      on a blocking cell or a node. Spawn and node order are sorted.
- [ ] `uniform_blocking`:
      - A veined stratum takes the `.blocking` memset path (the nav
        `blocked_count` equals the cell count, and the perception cache
        matches the per-cell result).
      - A lake + plains surface layer is `.mixed`, and the nav `blocked_count`
        equals the number of water cells plus blocking sparse features
        (matches a per-cell recount).
      - An all-grass surface layer is `.open`.
      - One walkable `setDenseTile` on a `.blocking` layer flips it to
        `.mixed`.
- [ ] `chunk_biomes` holds the center biome for every surface chunk and is
      identical across thread counts.
- [ ] Dig yield: digging a yield tile creates exactly one world item with a
      deterministic count; the same cell index on two levels rolls
      independently. A non-yield tile creates none.
- [ ] Unit tests stay at 16×16 or smaller with 1 underground level.
- [ ] (capacity audit) `levelBlocksMovement` reads one chunk's sparse list and
      one level's dense bands (the parity test passes), and
      `zig build bench -- --group nav-update-scattered` stays within
      max(3%, noise) of the pre-change run.
- [ ] Bench: add and run `zig build bench -- --group worldgen` (new
      `BenchmarkGroup`; `defaultItemCounts` = side lengths 64 / 128 / 256 with
      level counts 4 / 8 / 32 from a fixed per-size table, 256 matching the
      production config), reporting tiles/s across the shared `serial-direct`
      and `thread-fixed-auto` cases.
- [ ] A ReleaseSafe 60 s soak on the generated demo world:
      - Record `loading_build` before and after.
      - No `NavMemoryBudgetExceeded`.
      - Run the Slice 68A §3 re-baseline procedure on the generated world.
        The population row becomes the measured `min(2048, generated
        candidates)`; move the pre-58 table to History. (Replaced by Slices
        68A–68C.)
- [ ] `zig build verify` passes.

### VoidLight reference

Port:

- Biome classification from elevation × humidity thresholds, as data
  (`src/world/WorldGenerator.cpp:27-46,328-398`).
- Per-biome obstacle density (`:61-79`).
- Deposit rarity, which becomes veins plus `resources` yields (`:83+`).
- Decoration weights (`:145+`).
- Generation-safe validation before a harvest commit (`HarvestCommit.cpp:29-45`),
  mirrored by dig yields reading the old tile from the edit event.

Do not port:

- The `std::default_random_engine`-seeded Perlin permutation and the
  `uniform_real_distribution` draws (`WorldGenerator.cpp:169-196,306-341`).
  Distributions are implementation-defined, so the same seed differs across
  standard libraries.
- Float Perlin.
- Single generation-scoped RNG streams whose output depends on visit order
  (special-biome scatter `:335-341`).
- River flow walks (`RIVER_MAX_FLOW_STEPS`) and cluster growth that reads
  already-placed neighbors (order-dependent, cross-chunk).
- Progress callbacks, villages, and structures.
- `HarvestCommit`'s `std::random_device` yield roll (`HarvestCommit.cpp:59-64`).
- Scarcity radius scans and events (`:50-86`).

