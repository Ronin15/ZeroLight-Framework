## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64F](slice-64f.md) · Before: [Slice 65B](slice-65b.md), [Slice 46](slice-46.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Last work on `ai_update3`, before merge.

Goal: terrain and nav storage and work owned per chunk `(level, cx, cy)`, so a
dig, ramp, cave-in, or explosion costs work only in the chunks it touches,
memory follows content rather than level area, and nav processes per chunk so
threading scales with any number of updates and path requests
(`.claude/rules/engine-design.md` § Target scale).

### Current foundation

Terrain and nav are sized and processed per level, so a local change costs
level or world work:

- Terrain: `WorldSystem` holds per-level flat arrays (`dense_tile_ids`,
  sparse lists, `render_depths`) and a world-wide `level_links` list.
- Nav: `NavGrid` (one per level) and `NavLevelGraph` hold masks, components,
  slots, and edge windows for the whole level.
- `growChunkLinkCapacity` shifts every later slot on the level and remaps
  every edge target; `repackLevelEdges` (64F) repacks the whole level when one
  chunk's window overflows.
- `rebuildLinkEdges`, `addChunkLinkPortals`, and
  `WorldSystem.rampLinkOtherLevel` scan every world link; a batch touching
  more than 8 levels runs `relabelAllLevels`; the `affected_levels` loop is
  O(depth).
- Local A\* scratch is per-cell arrays sized to the level, per worker.
- The render path uploads terrain through a level-sized dense GPU window.
- Chunk edge sizes differ by system (`chunk_size_tiles`, `nav_chunk_tiles`,
  demo fixtures at 4 and 8 tiles).
- Untested from 64E/64F: two growths on one level from one link, both link
  endpoints in one chunk, growth of the last chunk; `nav-update-links-capacity`
  is benched only at 256².

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
- A step's nav apply is all-or-nothing: OOM leaves the graph intact and the
  edits buffered for retry; no degraded state, no full relabel fallback.
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
- [ ] Nav storage per chunk; per-level `NavGrid`/`NavLevelGraph` storage and
      its growth, repack, and relabel paths retired.
- [ ] Nav apply per step all-or-nothing over dirty chunks, threaded.
- [ ] Path search crosses chunks through the chunked graph with budget-sized
      scratch.
- [ ] Render terrain upload per chunk.
- [ ] Perception's line-of-sight state (`LevelBlockedSlot` and its
      per-level `pending_dirty` list, `systems/perception.zig`) lives on
      chunk storage, not a level-area bitmap.
- [ ] Static collision bodies reach nav on every level (live
      `markStaticBodies` covers level 0 only).
- [ ] Level-sized load gates (`validateDenseRenderBudget`,
      `NavMemoryBudget.check`) and the world-wide `level_link_limit` /
      `LevelLinkRoomUnreserved` gate (`world_system.zig`) retired, so creating
      a world in play (74) and adding a link are never refused for capacity.
- [ ] Fixed or retired with the old storage: `NavGraph.rebuild` writes
      dimensions before its memory check can fail; `markStaticBodies`
      allocates an `AutoHashMap` per call; the relabel OOM sweep.
- [ ] Tests: incremental equals a full rebuild, serial equals threaded; OOM at
      every allocation leaves state intact and the retry equals a rebuild; one
      chunk's change leaves every other chunk untouched; the 64E/64F gaps above;
      a multi-level cave-in in one step.
- [ ] Docs: `docs/architecture.md` terrain and pathfinding sections; 65B, 46,
      and 64B checked against chunk storage; archive 64F.

### Acceptance checks

- [ ] A `chunk-scale` bench group (dig, ramp, cave-in, explosion fill at
      256², 1024², 2048², and 8 / 32 / 128 levels) shows per-change cost flat
      across sizes (`.claude/rules/tests-benchmarks.md`).
- [ ] `pathfinding`, `nav-update-*`, and `render_game_prep` show no regression
      against a baseline taken before the first change; an A\* path of the same
      length costs the same at 2048² as at 256².
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [ ] Manual (display, Debug): digs, ramps, and a cave-in in the demo; NPCs
      route over the changes.
