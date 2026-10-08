## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: 64F · Before: 65B, 46 · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: decided (owner, 2026-10-07); not started.** Implements the target
terrain/nav model (`docs/architecture.md` § Chunk-Owned Terrain And Nav) in the
nine batches below.

### Why

Terrain (`dense_tile_ids`, per-level sparse lists) and nav (`NavGrid`,
`NavLevelGraph`) are sized per level. A local change then costs level or world
work:
- `growChunkLinkCapacity` shifts and remaps the whole level.
- `repackLevelEdges` repacks the whole level.
- `rebuildLinkEdges`, `addChunkLinkPortals` and `rampLinkOtherLevel` scan every
  world link.
- The relabel threshold runs `relabelAllLevels`; `affected_levels` is O(depth).

Full-extent sizing also cannot fit 2048² × many levels, and forces 65B to copy
the whole graph. Chunk-owned storage removes all of these at once. 64E's
failure modes (shared arena, relocation, holes, compaction, rebasing,
retryable ceiling) must not return.

### Model

**Geometry (`src/game/chunk.zig`).**
- Chunk edge `tiles = 16` is comptime: 256 cells, a local cell fits `u8`.
- Key: `ChunkKey{level: u16, cx: u16, cy: u16}`. A nav cell is a tile (load
  check `nav_cell_size == tile_size`).
- `BlockedBits` holds rows and columns as `[16]u16`, so any border is one
  `u16` and masks run as `@Vector(16, u16)`.
- The flat cell index stays the external id (caches, `CellCoord`); it never
  sizes anything. Cells of an edge chunk outside the world are blocked.

**Terrain chunk (`WorldSystem`).**
- Per level, a directory `[]?*TerrainChunk` (the only per-level sizing); each
  chunk is its own allocation.
- Each dense band is `union{uniform: TileId, cells: *[256]TileId}`,
  materialized on first edit, allocated before the write.
- A composite `BlockedBits` (bands plus sparse tiles), updated per write.
- Sparse tiles: a per-chunk `MultiArrayList{local, tile_id, depth, flags}`
  sorted by depth. A per-world refcounted depth set replaces `render_depths`.
- Link endpoint rows: append-only per chunk,
  `{local, partner_level, partner_cell, kind, cost, bidir}`. A link writes one
  row in each endpoint chunk. `rampLinkOtherLevel` is O(rows in the chunk).
- Each chunk carries `edit_gen`/`saved_gen` and a GPU page id per band; touched
  chunks join a per-step dirty list, deduplicated by a chunk stamp.
- Accessor signatures stay the same; they resolve directory → local cell.

**Render.**
- A GPU page pool holds one page per (chunk, band). A page table covers the
  visible chunk rect plus a one-chunk margin. Both are presentation pools sized
  from the viewport (~1k pages, ~0.5 MB).
- The quad covers the window rect only: the shader maps cell → window chunk →
  page → local cell.
- Edits become `(page, element)` writes. A chunk entering the window uploads on
  a per-frame budget. A visible chunk not yet resident draws nothing and is
  counted.

**Nav chunk (`NavGraph`; `NavGrid` and `NavLevelGraph` are deleted).**
- Masks: `blocked: BlockedBits`, `static: ?*BlockedBits`,
  `components: [256]u8`, `cell_to_slot: [256]u16`.
- Slots: 64 perimeter slots stored inline as SoA; their id is the perimeter
  position. Interior endpoint rows are a `MultiArrayList{cell, arc_head}` with
  slot = 64 + row, in link-row order. Slot ids never move.
- Edges: one exact `[]AbstractEdge` block per chunk, `windowCap(n) =
  max(2n, 32)`, with `target = packed struct(u32){slot: u16, dir: u3}` (self,
  N, E, S, W).
- Arcs: a per-chunk list `{partner key, partner local, cost, next}`, chained
  from endpoint rows.
- `neighbors: [4]*NavChunk` and a `dirty_epoch`.
- A shared `solid` sentinel stands in for all-blocked chunks: solid ground
  costs nothing.

**Apply** is all-or-nothing per step, with every allocation before any
mutation:
1. Sort the buffered edits by (level, chunk) once, and dispatch over the dirty
   chunks of every level together, using `[]*NavChunk` worker views.
2. Stage A (threaded): remask and recompute components into per-dirty-chunk
   staging, reserved before dispatch.
3. Stage B (threaded): measure each chunk's slots, edges and arcs into its own
   chunk header.
4. Stage C (main): allocate grown blocks and scratch. On OOM, free what was
   staged; the graph is untouched and the edits stay buffered for retry.
5. Stage D (threaded): commit. It cannot fail.
6. Stage E (main): free the old blocks.

No chunk is ever left degraded. Nothing is shared or relocated, and there is
no ceiling.

**Pairing and A\*.**
- Border pairing ANDs a chunk's edge `u16` with its neighbor's mirror edge and
  scans set bits with ctz. The midpoint rule is unchanged. A non-resident or
  solid neighbor gives no portals.
- Refs pack as `level<<40 | chunk_index<<16 | slot`.
- Expansion: one directory load, then edges contiguous within the chunk;
  targets resolve through `neighbors[dir]`; links walk the arc chain, then the
  partner directory, then the partner's `cell_to_slot`.
- The per-expansion binary search is deleted.

**Residency (`src/game/world_residency.zig`, one per world).**
- A chunk is resident if any of these hold:
  - the camera halo covers it (render only);
  - an agent occupies it;
  - an active path corridor crosses it;
  - an interest marker is in it.

  These are simulation state, so replay stays deterministic.
- Loads and evicts run at the structural-commit seam, under fixed per-step
  budgets, ordered (distance, level, cy, cx), with over-budget work deferred.
- A pristine chunk regenerates from the seed; an edited chunk loads from the
  per-chunk section store. Loading builds its nav chunk and dirty-marks its
  four neighbors.
- Evicting drops a pristine chunk and writes an edited one on the background
  lane. Edited chunks stay pinned until 46.
- A\* searches the resident subgraph. A search that reaches the frontier
  returns a transient `.non_resident`: it spills and is never negatively
  cached. Load and evict emit `nav_region_invalidated`.

**Memory.**
- Demo: terrain ≈1.4 MB (was ≈2 MB); nav ≈0.6 MB with solid ground, ≈15 MB
  fully open (was ≈39 MB).
- 2048² × 32 levels: at most ≈180 MB resident, independent of world size.

**65B.** Submit copies only the batch's dirty chunks. The swap exchanges
directory entries and neighbor pointers: O(dirty). `copyGraphFrom` is deleted.

**46.** One section per edited chunk: key, gen, bands, sparse rows, link rows.
Nav is never saved.

### Checklist

Each batch passes `zig build verify`, carries its tests and bench record, and
gets one review.

- [ ] **0. Verify** (zig-debug-specialist): static bodies can be queried per
  chunk in O(bodies in chunk); simulation-state residency is
  replay-deterministic.
- [ ] **1. Geometry.**
  - Add `chunk.zig`. Move the 4- and 8-tile fixtures to 16-tile with at least
    2×2 chunks.
  - Delete `chunk_size_tiles`, `default_chunk_size_tiles` and `nav_chunk_tiles`.
- [ ] **2. Terrain chunks and links.**
  - Add the directory, bands, bits, sparse rows and link rows, plus a
    `LinkAdded` event that replaces the link cursor. Perception reads chunk
    bits.
  - Delete the flat terrain arrays, `level_links` and its limit/room/reserve
    API, `ensureLevelLinkRoom`, `reserveLinkEdges`, `nav_links_processed`, the
    per-step link budget, and perception's level blocked cache.
  - Tests: accessor parity against a dense reference; FailingAllocator sweeps;
    ramp lookup parity against a scan.
- [ ] **3. Render pages.**
  - Add the page pool, page table and shader change.
  - Delete the dense GPU budget and full-world quads.
  - Tests: page-table builder, shader layout. Bench `render_game_prep`.
- [ ] **4. Nav masks.**
  - Add `NavChunk` masks, components and static bits, the directory and the
    solid sentinel.
  - Delete `NavGrid`.
- [ ] **5. Nav abstract.**
  - Add slots, rows, blocks, arcs and the new A\*.
  - Delete `NavLevelGraph`, the link edge and ref tables, `rebuildLinkEdges`,
    `growChunkLinkCapacity`, `repackLevelEdges` and its scratch, the
    interior-capacity helpers and floor, the repack metrics, and
    `maxLevelEdgeSlots`. Index widths become comptime asserts.
- [ ] **6. Staged apply.**
  - Delete `relabelAllLevels`, the relabel threshold, `affected_levels`,
    `nav_dirty_levels`, `changed_chunks`, `dirty_stamp` and
    `nav_apply_degraded`.
  - Tests: incremental equals a full rebuild, serial and threaded; OOM at
    every allocation index leaves bytes identical and the retry equals a
    rebuild; one chunk's growth leaves every other chunk byte- and
    pointer-identical; a 12-level × 16-chunk cave-in in one step equals a
    rebuild, serial equals threaded.
- [ ] **7. Scratch.**
  - Local A\* uses a stamped hash sized 2 × `max_explored_nodes`, and group
    fields use 256-cell pages.
  - Delete the per-cell search and field arrays.
- [ ] **8. Residency.**
  - Tests: load/evict parity against all-resident; the frontier
    `.non_resident` result; deferral order; replay determinism.
- [ ] **9. Docs.**
  - Rewrite the 65B and 46 slices and `architecture.md` Pathfinding.

### Acceptance checks

- [ ] A new `chunk-scale` bench group covers dig, ramp, a 4×4×3 cave-in and
  fill at 256², 1024² and 2048², plus 8 / 32 / 128 levels. Cost per change
  stays flat within spread.
- [ ] `pathfinding` and `render_game_prep` show no regression (ReleaseFast,
  3 interleaved reps, max(3%, spread)). A 2048² A\* case costs the same as
  256².
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
