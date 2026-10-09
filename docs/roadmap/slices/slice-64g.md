## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Before: [Slice 65B](slice-65b.md), [Slice 46](slice-46.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** Last work on `ai_update3`, before merge.

Goal: terrain and nav storage and work owned per chunk `(level, cx, cy)`, so a
dig, ramp, cave-in, or explosion costs work only in the chunks it touches,
memory follows content rather than level area, and nav processes per chunk so
threading scales with any number of updates and path requests
(`.claude/rules/engine-design.md` § Target scale).

### Current foundation

Reference: main's nav (`main:src/game/systems/pathfinding/`). The branch's
nav storage, level-link, and nav-apply changes since main are replaced, never
extended, reused, or used as a baseline (owner decision, 2026-10-08). The Zig
0.17 migration and the Slice 72 and 71B.1 changes in the same files stay.

Main already partitions nav by chunk: positional per-chunk portal slots,
chunk-local components (a flood never crosses a chunk border), a dirty-chunk
patch that re-derives touched chunks from the world, threaded remask and patch
stages with per-stage tuners, cell-keyed level links, goal-keyed caches, and
fixed node budgets with a two-attempt retry. Its storage, fallbacks, and
per-change work are still sized by level, world, or content totals. Numbers are
derived for one 2048² level (4,194,304 cells, 16-cell nav chunks, 16,384
chunks); multiply by depth and world count.

Storage sized to level area:

- `NavGrid` (`nav_grid.zig:43,47,53`): `blocked` 1 B + `components` 4 B per
  cell, plus `static_blocked` 1 B per cell on level 0 → 20 MiB per level.
- `NavLevelGraph.cell_to_portal` (`nav_graph.zig:83`): 4 B per cell → 16 MiB
  per level.
- Slot geometry (`nav_graph.zig:355`, `computePortalGeometry` `:1116`): 64
  slots for every chunk (60 perimeter cells), all-solid or uniform included,
  × 32 B (portal, edge range, order, label keys and starts,
  `nav_graph.zig:1163-1168`) = 32 MiB per level. Every level also reserves the
  interior link endpoints of every level (`:367-372,1122-1171`).
- Together ≈ 68 MiB per level before edges, ≈ 8.5 GiB for 128 levels of one
  world, whatever the content.
- `SearchScratch.cells` (`scratch.zig:218`, `system.zig:280,413`): a level's
  cell count per participant (workers + main), 13 B per cell ≈ 52 MiB each.
- Group flow fields (`group_field.zig:90-106`, `system.zig:404-406`): every
  field up to `max_group_fields` reserved at nav build, 21 B per cell ≈ 84 MiB
  each.
- Terrain: `WorldSystem.dense_tile_ids` is one flat array, 2 B per cell per
  dense layer, up to `max_dense_bands_per_level` (2) layers per level → up to
  16 MiB per level; the uniform-fill flag is per layer and one dig clears it
  (`world_system.zig:127,291,1187`).
- Perception: `LevelBlockedSlot` is a 1 B per cell bitmap → 4 MiB per level,
  with a `pending_dirty` list that grows on levels nobody observes
  (`perception.zig:429,462`).
- Render: one world-wide dense tile buffer, 4 B per cell per dense layer,
  uploaded once at load; `addDenseLayer` is refused after the upload
  (`world_system.zig:643,1227-1234,1585`).

Work sized to the world, a level, or content totals:

- Every incremental apply clears every pending request and negative result
  and drops every group field, world-wide (`system.zig:494-495`).
- Cached-path eviction scans the whole result cache per batch on the main
  thread, and a stride-downsampled path is evicted whenever its level is
  touched (`caches.zig:344-356,404`).
- The blocked query behind every chunk remask scans every dense layer in the
  world and the level's sparse tiles per cell (`world_system.zig:1413-1428`).
- Static obstacles: the coverage refresh scans every static body per covered
  cell (`nav_grid.zig:150-158,382-392`); an unresolvable rect marks the whole
  level dirty (`system.zig:579-583`); `markStaticBodies` covers level 0 only
  and builds an `AutoHashMap` per call (`nav_grid.zig:105,116`).
- Links: each patched chunk scans every world link (`nav_graph.zig:1477-1484`);
  endpoint dedupe is O(links²) (`:1174-1184`); `rebuildLinkEdges` rebuilds
  every link edge per batch (`:740,1249`); `WorldSystem.rampLinkOtherLevel`
  scans every link on every entity cell entry (`world_system.zig:1396`,
  `dig_controller.zig:226,261`).
- An edge-window overflow rebuilds every level's abstract graph, doubles the
  edge slack of every chunk on every level for good, and bumps `nav_version`,
  which clears every cache, pending request, and group field
  (`nav_graph.zig:725-737,744-749`, `system.zig:479-482`).
- A batch touching more than 8 levels relabels and rebuilds every level, with
  the same version bump (`nav_graph.zig:702-709`, `types.zig:142`).
- Runtime ramps: an interior endpoint is skipped until a full rebuild, which
  runs only at init or in the fallbacks above (`nav_graph.zig:1497`, test
  `:2215`); `digRamp` edits only the dug level, so the partner level is not
  patched (`dig_controller.zig:169`); a ramp on walkable floor flips no
  `blocks_movement`, so nav filters its tile event (`system.zig:684`).
- Cross-level search uses a zero heuristic off the goal level
  (`solve.zig:401-404`), so it explores every level it reaches within its node
  budget and far cross-level goals exhaust both attempts.
- Creating a level or world: the abstract build is serial per chunk and level
  (`nav_graph.zig:580-593`), perception prebuilds every level serially
  (`perception.zig:543-548`), and a nav rebuild clears all runtime state
  (`system.zig:420`).
- Perception rebuilds a whole level when dirty area passes 25% of it
  (`perception.zig:394-404`).

Failure and limits:

- Not all-or-nothing: `NavGraph.rebuild` bumps the version and writes
  dimensions and every level's arrays before steps that can fail
  (`nav_graph.zig:466-500`); `applyNavUpdates` remasks before patching, a
  worker OOM is treated as an edge overflow (`:237-243`), and
  `rebuildLinkEdges` clears before it appends (`:1250-1268`).
- A nav-apply error skips that step's perception and steering reactions
  (`game_demo_state.zig:673-675`).
- Load gates sized to level area refuse worlds: `NavMemoryBudget.check`
  (`nav_memory.zig:191`) and `validateDenseRenderBudget`
  (`world_system.zig:647`). The nav gate is also the only loud check on index
  widths (cell, label, slot, edge); elsewhere they are Debug asserts
  (`nav_graph.zig:1118`).
- Chunk edge sizes differ by system: `chunk_size_tiles` 16 in
  `WorldBuildConfig` and 8 in `default_chunk_size_tiles`
  (`world_system.zig:48,125`), nav chunks 16 nav cells (`types.zig:130`) with
  the nav cell size set apart from the tile size
  (`simulation_pipeline.zig:288`), test fixtures 4 and 8.
- No bench varies level size or depth at a fixed change: `nav-update-*` runs
  one 256² world (`nav_update.zig:52`), and `pathfinding*` stays at or below
  256² on one level.

### Architecture notes

- Owner direction (2026-10-07, 2026-10-08): the chunk is the unit of terrain
  and nav storage, change, work, threading, and save; nav covers the whole
  world; nothing is evicted from the simulation
  (`.claude/rules/engine-design.md`, `.claude/rules/budgets-capacities.md`).
- A level holds a directory of its chunks; nothing is sized to level area or
  world extent. Uniform and all-solid chunks stay cheap.
- A local change touches only its chunks; a dense change processes its dirty
  chunks in parallel; creating or destroying a level or world costs its own
  chunks.
- A ramp dug at runtime is routable the same step on both levels, perimeter or
  interior endpoint, and is never refused.
- A step's nav apply is all-or-nothing: OOM leaves the graph intact and the
  edits buffered for retry; no degraded state and no level- or world-wide
  fallback rebuild.
- Path requests fan out against the read-only chunked graph; a request's
  scratch follows its node budget, never level cells
  (`.claude/rules/pathfinding.md`).
- Serial equals threaded, and incremental equals a full rebuild
  (`.claude/rules/threading.md`, `.claude/rules/simulation.md`).
- Render presentation pools may be sized from the viewport; nothing in render
  is sized to level area (`.claude/rules/render.md`).
- Provides: 65B copies and swaps only dirty chunks; 46 saves terrain per
  chunk; 64B normalizes perception's chunk-owned LOS state; 38 gets static
  collision bodies in nav on every level; 74 creates and destroys worlds by
  their chunks; 75 paths far-off agents over the whole-world graph.
- Accessor contracts used by gameplay, perception, and render stay the same.

### Checklist

- [x] One chunk edge size (power of two, at most 16) and tile-sized nav cells
      shared by terrain, nav, and scope (`23c24ec`).
- [x] Terrain stored per chunk behind the existing accessors; the blocked
      query costs its chunk (`453993f`).
- [ ] Uniform and all-solid chunks stay cheap after edits elsewhere on their
      level. Terrain landed (`453993f`); nav remains.
- [ ] Level links stored with their endpoint chunks; a link lookup, including
      on entity cell entry, costs the chunk, not the world's links. World side
      landed (`453993f`); nav side remains.
- [ ] Nav storage per chunk; a level holds only a directory of its chunks,
      and nothing in nav is sized to level cells.
- [ ] Runtime ramps routable the same step on both levels, perimeter or
      interior, never refused.
- [ ] Nav apply per step all-or-nothing over dirty chunks, threaded; no
      relabel or full-rebuild fallback.
- [ ] A local nav change leaves pending requests, negative results, group
      fields, and cached paths outside its chunks untouched; path eviction
      costs the results that touch its chunks, not the cache size.
- [ ] A static obstacle add, move, or destroy costs its footprint chunks,
      independent of static-body and entity counts, on every level, with no
      whole-level fallback and no per-call map.
- [ ] Path search crosses chunks and levels through the chunked graph with
      budget-sized scratch; a cross-level path's cost follows path length, not
      levels explored; group flow fields not sized to level cells.
- [ ] A level or world added in play builds only its own chunks, threaded, and
      is never refused; other levels' nav, caches, and runtime state are
      untouched.
- [x] Render terrain uploaded per chunk for the render window; dense layers
      added in play; GPU byte gate replaced by a report (`9bbfdc0`).
- [ ] A world's GPU tile store is released when its world is destroyed or
      replaced, never only at renderer shutdown.
- [ ] Perception's line-of-sight state lives on chunk storage, not a
      level-area bitmap; its rebuild threshold derives from operation cost, not
      level area.
- [ ] A nav-apply failure leaves that step's perception and steering
      reactions intact.
- [ ] Level-sized load gates retired, so creating a world in play (74) and
      adding a link are never refused for capacity; index and format widths
      (cell, chunk, label, slot, edge offsets, level) fail loudly at world
      create, load, and growth. Index widths landed (`23c24ec`); gates remain.
- [x] Replaced branch nav code and its tests removed; main's nav restored
      (`2c09cec`).
- [ ] Tests: incremental equals a full rebuild, serial equals threaded; OOM at
      every allocation leaves state intact and the retry equals a rebuild; one
      chunk's change leaves every other chunk untouched; a multi-level cave-in
      in one step; a runtime ramp routable the same step on both levels; one
      dig leaves unrelated pending requests, group fields, and cache entries
      intact; a static-obstacle move costs the same at 10 and 10k static
      bodies.
- [ ] Docs: `docs/architecture.md` terrain and pathfinding sections; 65B, 46,
      and 64B checked against chunk storage.

### Acceptance checks

- [ ] `chunk-scale-*` bench groups at 256², 1024², 2048², and 8 / 32 / 128
      levels (`.claude/rules/tests-benchmarks.md`): dig, ramp, cave-in, and
      explosion fill flat across sizes; level and world create and destroy flat
      across depth and world count and linear in their own chunks. Fixtures
      build once outside the timed loop and the groups run quickly in Debug.
- [ ] An A\* path of the same length costs the same at 2048² as at 256²
      (`pathfinding*` groups), and a cross-level path of the same length costs
      the same at 8, 32, and 128 levels.
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [ ] Manual (display, Debug): digs, ramps, and a cave-in in the demo; NPCs
      route over the changes.
