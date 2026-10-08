## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64F](slice-64f.md) · Before: [Slice 65B](slice-65b.md), [Slice 46](slice-46.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Owner direction (2026-10-07): the chunk is the unit
of terrain and nav storage, change, threading, residency, copy, and save. The
model below is a design draft to that direction; batch 0 and a
`zig-design-specialist` pass confirm it before batch 1.

Goal: terrain and nav storage owned per chunk `(level, cx, cy)`, so a dig,
ramp, cave-in, or explosion costs work in the chunks it touches, memory follows
resident content rather than world extent, and 65B and 46 copy or save only
dirty chunks (`.claude/rules/budgets-capacities.md`,
`docs/architecture.md` § Target Model).

### Current foundation

Terrain (`dense_tile_ids`, per-level sparse lists) and nav (`NavGrid`,
`NavLevelGraph`) are sized per level, so a local change costs level or world
work:

- `growChunkLinkCapacity` shifts every later slot on the level across six
  arrays and remaps every edge target; `repackLevelEdges` (64F) repacks the
  whole level on one chunk's overflow.
- `rebuildLinkEdges`, `addChunkLinkPortals`, and
  `WorldSystem.rampLinkOtherLevel` scan every world link.
- A batch touching more than 8 levels runs `relabelAllLevels`; the
  `affected_levels` loop is O(depth).
- Full-extent sizing cannot fit 2048² × many levels and forces 65B to copy the
  whole graph.

64E/64F test gaps this slice closes: two growths on one level from one link
(the summed reserve), both link endpoints in one chunk, growth of the last
chunk; `nav-update-links-capacity` is benched only at 256².

### Architecture notes

**Geometry (`src/game/chunk.zig`).**
- Chunk edge `tiles = 16` is comptime: 256 cells, a local cell fits `u8`.
- Key `ChunkKey{level: u16, cx: u16, cy: u16}`; a nav cell is a tile (load
  check `nav_cell_size == tile_size`).
- `BlockedBits` holds rows and columns as `[16]u16`: any border is one `u16`;
  mask math goes through a paired scalar/SIMD `u16x16` helper added to
  `src/core/simd.zig` (`.claude/rules/memory-performance.md`).
- The flat cell index stays the external id (caches, `CellCoord`) and never
  sizes anything. Edge-chunk cells outside the world are blocked.

**Terrain chunk (`WorldSystem`).**
- Per level, a directory `[]?*TerrainChunk` (the only per-level sizing); each
  chunk is its own allocation.
- Each dense band is `union{uniform: TileId, cells: *[256]TileId}`,
  materialized on first edit, allocated before the write.
- A composite `BlockedBits` (bands plus sparse tiles), updated per write.
- Sparse tiles: per-chunk `MultiArrayList{local, tile_id, depth, flags}`
  sorted by depth; a per-world refcounted depth set replaces `render_depths`.
- Link endpoint rows, append-only per chunk:
  `{local, partner_level, partner_cell, kind, cost, bidir}`; a link writes one
  row in each endpoint chunk, so `rampLinkOtherLevel` is O(rows in the chunk).
- Each chunk carries `edit_gen`/`saved_gen` and a GPU page id per band; touched
  chunks join a per-step dirty list deduplicated by a chunk stamp.
- Accessor signatures stay the same; they resolve directory → local cell.

**Render.**
- A GPU page pool holds one page per (chunk, band); a page table covers the
  visible chunk rect plus a one-chunk margin. Both are presentation pools
  sized from the viewport.
- The quad covers the window rect only: the shader maps cell → window chunk →
  page → local cell.
- Edits become `(page, element)` writes. A chunk entering the window uploads
  on a fixed per-frame budget; a visible chunk not yet resident draws nothing
  and is counted.

**Nav chunk (`NavGraph`; `NavGrid` and `NavLevelGraph` are removed).**
- Masks: `blocked: BlockedBits`, `static: ?*BlockedBits`,
  `components: [256]u8`, `cell_to_slot: [256]u16`.
- Slots: 64 perimeter slots inline as SoA, id = perimeter position. Interior
  endpoint rows are a `MultiArrayList{cell, arc_head}` with slot = 64 + row, in
  link-row order. Slot ids never move.
- Edges: one exact `[]AbstractEdge` block per chunk, `windowCap(n) =
  max(2n, 32)`, `target = packed struct(u32){slot: u16, dir: u3}` (self, N, E,
  S, W).
- Arcs: per-chunk `{partner key, partner local, cost, next}`, chained from
  endpoint rows.
- `neighbors: [4]*NavChunk` and a `dirty_epoch`.
- A shared `solid` sentinel stands in for all-blocked chunks.

**Apply** is all-or-nothing per step, every allocation before any mutation:
1. Sort buffered edits by (level, chunk) once; dispatch over the dirty chunks
   of every level together through `[]*NavChunk` worker views.
2. Stage A (threaded): remask and recompute components into per-dirty-chunk
   staging reserved before dispatch.
3. Stage B (threaded): measure each chunk's slots, edges, and arcs into its own
   header.
4. Stage C (main): allocate grown blocks and scratch. On OOM, free what was
   staged; the graph is untouched and the edits stay buffered for retry.
5. Stage D (threaded): commit; cannot fail.
6. Stage E (main): free the old blocks.

No chunk is left degraded; nothing is shared or relocated; no ceiling.

**Pairing and A\*.**
- Border pairing ANDs a chunk's edge `u16` with its neighbor's mirror edge and
  scans set bits with ctz; the midpoint rule is unchanged. A non-resident or
  solid neighbor gives no portals.
- Refs pack as `level<<40 | chunk_index<<16 | slot`.
- Expansion: one directory load, edges contiguous within the chunk, targets
  through `neighbors[dir]`, links through the arc chain → partner directory →
  partner `cell_to_slot`. The per-expansion binary search is removed.

**Residency (`src/game/world_residency.zig`, one per world).**
- Simulation residency: a chunk is resident while the fixed-step `sim_view`
  halo covers it, an agent occupies it, an active path corridor crosses it, or
  an interest marker is in it. All four are simulation state, so replay stays
  deterministic; the render camera never makes a chunk simulation-resident
  (`.claude/rules/simulation.md`). Chunks visible only to the render camera
  get GPU pages from loaded terrain and draw nothing until resident.
- Loads and evicts run at the structural-commit seam under fixed per-step
  budgets, ordered (distance, level, cy, cx), over-budget work deferred.
- A pristine chunk regenerates from the seed; an edited chunk loads from the
  per-chunk section store. Loading builds its nav chunk and dirty-marks its
  four neighbors.
- Evicting drops a pristine chunk and writes an edited one on the background
  lane; edited chunks stay pinned until 46.
- A\* searches the resident subgraph. A search reaching the frontier returns a
  transient `.non_resident` (spills; never negatively cached). Load and evict
  emit `nav_region_invalidated`.

**Cost model (derived).** Demo terrain ≈1.4 MB (was ≈2 MB); nav ≈0.6 MB with
solid ground, ≈15 MB fully open (was ≈39 MB). 2048² × 32 levels: at most
≈180 MB resident, independent of world size. Local change: O(touched chunks);
dense change: O(dirty chunks), threaded; world/level create and destroy:
O(resident chunks).

**65B.** Submit copies only the batch's dirty chunks; the swap exchanges
directory entries and neighbor pointers, O(dirty). `copyGraphFrom` is removed.

**46.** One section per edited chunk: key, gen, bands, sparse rows, link rows.
Nav is never saved.

### Checklist

- [ ] **0. Verify** (`zig-debug-specialist`): static bodies can be queried per
  chunk in O(bodies in chunk); simulation-state residency is
  replay-deterministic. Then a `zig-design-specialist` pass confirms the model.
- [ ] **1. Geometry.** Add `chunk.zig` and the `simd.zig` `u16x16` helper;
  move the 4- and 8-tile fixtures to 16-tile with at least 2×2 chunks; remove
  `chunk_size_tiles`, `default_chunk_size_tiles`, and `nav_chunk_tiles`.
  Update the fixture rule in `.claude/rules/tests-benchmarks.md` (multi-chunk
  tests use 16-tile chunks; the procedural fixture cap becomes 2×2 chunks) in
  the same change.
- [ ] **2. Terrain chunks and links.** Add the directory, bands, bits, sparse
  rows, and link rows, plus a `LinkAdded` event that replaces the link cursor;
  perception reads chunk bits. Remove the flat terrain arrays, `level_links`
  and its limit/room/reserve API, `ensureLevelLinkRoom`, `reserveLinkEdges`,
  `nav_links_processed`, the per-step link budget, and perception's level
  blocked cache. Tests: accessor parity against a dense reference;
  FailingAllocator sweeps; ramp lookup parity against a scan.
- [ ] **3. Render pages.** Add the page pool, page table, and shader change;
  remove the dense GPU budget and full-world quads. Tests: page-table builder,
  shader layout. Bench `render_game_prep`.
- [ ] **4. Nav masks.** Add `NavChunk` masks, components, static bits, the
  directory, and the solid sentinel; remove `NavGrid`.
- [ ] **5. Nav abstract.** Add slots, rows, blocks, arcs, and the new A\*.
  Remove `NavLevelGraph`, the link edge and ref tables, `rebuildLinkEdges`,
  `growChunkLinkCapacity`, `repackLevelEdges` and its scratch, the
  interior-capacity helpers and floor, the repack metrics, and
  `maxLevelEdgeSlots`; index widths become comptime asserts.
- [ ] **6. Staged apply.** Remove `relabelAllLevels`, the relabel threshold,
  `affected_levels`, `nav_dirty_levels`, `changed_chunks`, `dirty_stamp`, and
  `nav_apply_degraded`. Tests: incremental equals a full rebuild, serial and
  threaded; OOM at every allocation index leaves bytes identical and the retry
  equals a rebuild; one chunk's growth leaves every other chunk byte- and
  pointer-identical; two links on one chunk, both endpoints in one chunk, and
  the last chunk; a 12-level × 16-chunk cave-in in one step equals a rebuild,
  serial equals threaded.
- [ ] **7. Scratch.** Local A\* uses a stamped hash sized 2 ×
  `max_explored_nodes`; group fields use 256-cell pages; remove the per-cell
  search and field arrays.
- [ ] **8. Residency.** Tests: load/evict parity against all-resident; the
  frontier `.non_resident` result; deferral order; replay determinism.
- [ ] **9. Docs.** Rewrite the 65B, 46, and 64B (normalize fields
  `nav_links_processed`, `nav_apply_degraded`, `levelLinks()`) slices, 72's
  re-scoped items, and `docs/architecture.md` Pathfinding; update
  `.claude/rules/pathfinding.md` for chunk-owned nav; retire 64E and 64F to
  the archive.

### Acceptance checks

- [ ] A `chunk-scale` bench group covers dig, ramp, a 4×4×3 cave-in, and fill
  at 256², 1024², and 2048², plus 8 / 32 / 128 levels; cost per change stays
  flat across sizes (`.claude/rules/tests-benchmarks.md`).
- [ ] `pathfinding` and `render_game_prep` show no regression; a 2048² A\* case
  costs the same as 256².
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
