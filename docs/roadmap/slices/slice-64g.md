## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Before: [Slice 65B](slice-65b.md), [Slice 46](slice-46.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Last work on `ai_update3`, before merge.

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
stages, and cell-keyed level links. Its storage and fallbacks are still sized
per level or world. Numbers are derived for one 2048² level (4,194,304 cells,
16-tile nav chunks, 16,384 chunks); multiply by depth and world count:

- `NavGrid` (`nav_grid.zig:43,47,53`): `blocked` 1 B + `components` 4 B per
  cell, plus `static_blocked` 1 B per cell on level 0 → 20 MiB per level.
- `NavLevelGraph.cell_to_portal` (`nav_graph.zig:83`): 4 B per cell → 16 MiB
  per level.
- Slot geometry (`nav_graph.zig:355`, `computePortalGeometry` `:1116`):
  64 perimeter slots for every chunk, all-solid or uniform included →
  1,048,576 slots × 32 B (portal, edge range, order, label keys and starts,
  `nav_graph.zig:1163-1168`) = 32 MiB per level.
- Together ≈ 68 MiB per level before edges, ≈ 8.5 GiB for 128 levels of one
  world, whatever the content.
- `SearchScratch.cells` (`scratch.zig:218`, `system.zig:413`): resized to a
  level's cell count, 13 B per cell per worker ≈ 52 MiB per worker.
- Group flow fields (`group_field.zig:90-106`, `system.zig:405`): 21 B per
  cell per field ≈ 84 MiB per field, every field up to `max_group_fields`.
- Edge windows are fixed per chunk with slack; one overflowing chunk rebuilds
  every level's abstract graph and bumps `nav_version`, invalidating every
  cached path (`nav_graph.zig:725-737`).
- A batch touching more than 8 levels relabels every level
  (`nav_graph.zig:702`, `types.zig:142`): O(levels × cells).
- `rebuildLinkEdges` scans every world link on every batch
  (`nav_graph.zig:740,1249`); `WorldSystem.rampLinkOtherLevel` scans every
  world link per lookup (`world_system.zig:1396`).
- A ramp dug at runtime with an interior endpoint gets no portal until a full
  rebuild, its partner level is not patched, and a ramp on an already-walkable
  cell emits no nav event (`nav_graph.zig:2215` test; `digRamp` edits only
  the dug level, `dig_controller.zig:169`).
- `markStaticBodies` covers level 0 only and builds an `AutoHashMap` per call
  (`nav_grid.zig:105,116`); `NavGraph.rebuild` writes dimensions before its
  memory check can fail (`nav_graph.zig:466-470`).
- Load gates sized to level area refuse worlds: `NavMemoryBudget.check`
  (`nav_memory.zig:191`) and `validateDenseRenderBudget`
  (`world_system.zig:647`).
- Terrain: `WorldSystem.dense_tile_ids` is a flat per-dense-layer array,
  2 B per cell per layer (8 MiB per layer per level), and `level_links` is
  one world-wide list (`world_system.zig:288,291`).
- Perception: `LevelBlockedSlot` keeps a per-level bitmap with a
  `pending_dirty` list (`perception.zig:429,462`).
- Render uploads terrain through a level-sized dense GPU window: 4 B per cell
  per dense layer, 16 MiB per layer per level (`world_system.zig:643`).
- Chunk edge sizes differ by system: `chunk_size_tiles` 16 in
  `WorldBuildConfig` and 8 in `default_chunk_size_tiles`
  (`world_system.zig:48,125`), nav chunks 16 (`types.zig:130`), test fixtures
  4 and 8.

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

- [ ] One chunk edge size shared by terrain, nav, and scope; test fixtures are
      multi-chunk (fixture rule in `.claude/rules/tests-benchmarks.md` updated
      in the same change if it moves).
- [ ] Terrain storage owned per chunk behind the existing accessors.
- [ ] Level links stored with their endpoint chunks; a ramp lookup costs the
      chunk, not the world's links.
- [ ] Nav storage per chunk; nothing in nav sized to level cells or level
      chunk count.
- [ ] Runtime ramps routable the same step on both levels, perimeter or
      interior, never refused.
- [ ] Nav apply per step all-or-nothing over dirty chunks, threaded; no
      relabel or full-rebuild fallback.
- [ ] Path search crosses chunks through the chunked graph with budget-sized
      scratch; group flow fields not sized to level cells.
- [ ] Render terrain upload per chunk.
- [ ] Perception's line-of-sight state lives on chunk storage, not a
      level-area bitmap.
- [ ] Static collision bodies reach nav on every level, without a per-call
      map.
- [ ] Level-sized load gates retired, so creating a world in play (74) and
      adding a link are never refused for capacity.
- [ ] The replaced branch nav code is gone, with its tests, as each part is
      replaced.
- [ ] Tests: incremental equals a full rebuild, serial equals threaded; OOM at
      every allocation leaves state intact and the retry equals a rebuild; one
      chunk's change leaves every other chunk untouched; a multi-level cave-in
      in one step; a runtime ramp routable the same step on both levels.
- [ ] Docs: `docs/architecture.md` terrain and pathfinding sections; 65B, 46,
      and 64B checked against chunk storage.

### Acceptance checks

- [ ] A `chunk-scale` bench group (dig, ramp, cave-in, explosion fill at
      256², 1024², 2048², and 8 / 32 / 128 levels) shows per-change cost flat
      across sizes (`.claude/rules/tests-benchmarks.md`); fixtures build once
      outside the timed loop and the group runs quickly in Debug.
- [ ] An A\* path of the same length costs the same at 2048² as at 256²
      (`pathfinding*` groups).
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [ ] Manual (display, Debug): digs, ramps, and a cave-in in the demo; NPCs
      route over the changes.
