## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (sprite-prep tuner), [Slice 85](slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Routed by the 64G combined review (area C). The
render backend pass closes the core branch and comes after the collect moves,
so the same files are touched once; 88 follows the collect items, before
the backend pass (index, merged order).

Goal: render collect work and its record and command capacity follow the
rows in the visible chunks, never the world's population. The GPU tile sync's
per-change copying stays off the main thread. The renderer, sprite batch,
text, and GPU buffers meet the cost model and `.claude/rules/render.md`.

### Current foundation

- `render_prep.collectDynamicRecords` (`src/game/render_prep.zig:362`) walks
  every movement body (`:385`) on main each frame. For each row it tests the
  level window and the visible chunks.
- `dynamicRecordCapacity` (`:302`) and `spriteCommandCapacity` (`:311`) size
  to every primitive visual in the world.
- GPU tile sync: `GpuTileMirror.plan` and `commit`
  (`src/game/world/gpu_tiles.zig:266`, `:446`) copy a batched change's
  written layers serially; the batched `chunk-scale-gpu-sync-dig` variant is
  serial only.
- Measured:
  - `render-game-prep-offview`, serial (Debug, `5d5a089`): collect goes
    0.44 → 1.37 → 8.6 ms as the off-view rows go 4,096 → 32,768 → 262,144,
    with the same 1,088 records collected each time (1,024 rows in view plus
    particles). The capacities follow the total rows.
  - `chunk-scale-gpu-sync-dig`, batched (Debug, `639f55d`): about 2 ms on main
    for 32 written layers, linear in what changed.

### Architecture notes

- Render visibility is the camera chunk window plus AABB
  (`.claude/rules/render.md`). Collect cost follows what is visible
  (`.claude/rules/engine-design.md` § Cost model).
- The record and command capacities grow at the pre-reserve before the
  submission pass (`.claude/rules/memory-performance.md`), and the GPU tile
  sync's byte copying threads (`.claude/rules/threading.md`).
- Render state and draw records are per world (`.claude/rules/render.md`);
  74 binds presentation to the viewed world.
- The backend pass is review-only (`zig-best-practices-review`), followed by
  local fixes.

### Checklist

- [ ] Collect walks the visible chunks' rows. Failure scenario: off-view
      population raises frame cost and reserved vertex memory with nothing
      more drawn. The visible rows are scattered over the movement store
      (append and swap-remove order, `data_system/movement.zig:67`, `removeAt` `:189`), and
      collect resolves each row's level by slot (`render_prep.zig:388`)
      before its chunk test (`:395`). Constraint: the per-visible-chunk
      source reads each (level, chunk)'s rows as one contiguous run
      (contiguity audit H4; `.claude/rules/memory-performance.md`
      § Data-oriented design); the source is this slice's design.
      Measured: `render-game-prep-offview` above. Pass: collect time and the
      record and command capacities flat in off-view rows (group doc); the
      shape asserts land with the fix.
- [ ] GPU sync copying off main. Failure scenario: an explosion's batched
      change costs main time linear in the bytes it wrote. Measured: about
      2 ms for 32 layers. Pass: main keeps only the ordered upload commit;
      serial == threaded; `chunk-scale-gpu-sync-dig` gains threaded cases.
- [ ] Sparse tiles read as contiguous runs per (level, chunk) (contiguity
      audit M1). Failure: `sparse_tiles` (`world/system.zig:275`) links its
      rows newest-first per (level, chunk) through `chunk_next` and
      `chunk_prev` (`:194-195`) over one world-wide pool, and
      `walkWindowSparseTiles` (`world/render.zig:178`) walks each window
      chunk's list, reading `cell_index` from scattered pool rows;
      `addSparseTile` appends in call order (`world/edit.zig:726`), so
      worldgen order already interleaves chunks
      (`.claude/rules/memory-performance.md` § Data-oriented design). Failure
      scenario: the walk reruns whenever the window crosses a tile edge
      (`world/system.zig:277-280`), walking fragments, more scattered after
      dig and build churn. Pass: the window walk reads each chunk's sparse
      rows as one contiguous run; churned and interleaved-creation
      `render-sparse-window-pan` cases match a chunk-ordered one.
- [ ] Render submit reads its records in sort order (contiguity audit M2).
      Failure: `DynamicScenePrep` sorts an index array, `sort_indices`, by
      (depth, sequence) (`render_prep.zig:216`, sorted at `:266`), its comparator loading two
      records per compare (`:726-731`), and submit reads
      `records[record_index]` through it (`:270-271`); the sparse window sorts
      row ids over three pool columns (`world/render.zig:231`), and
      `emitSparseRange` (`:627`) reads each row by id
      (`.claude/rules/memory-performance.md` § Data-oriented design, § Hot
      paths). Failure scenario: every frame reads the visible records out of
      order, and the sort chases two records per compare. Pass: the dynamic
      submit and the sparse emit each read their sorted rows in memory order;
      `render-game-prep` within spread or faster.
- [ ] Render backend pass, last on the core branch: the renderer, sprite
      batch, text, and GPU buffers, plus `src/render/camera.zig`,
      `debug_overlay.zig`, `fps_counter.zig`, and `resources.zig`, which no
      other pass covers (docs audit L5), against the cost model and
      `render.md`; local fixes land here, and structural findings become
      items here.
- [ ] The whole subsystem checked against the cost model and the rules
      (owner 2026-10-16), not only the items above: `src/game/render_prep.zig`
      the GPU tile sync (`src/game/world/gpu_tiles.zig`), `world/render.zig`,
      `render_depth.zig`, and the `data_system/visual.zig` store. Each finding
      becomes an item here.
- [x] The `render_game_prep` bench's module doc carries no review tags
      (`baa4e62`; `src/benchmarks/render_game_prep.zig:5-10` states what the
      group measures).
- [ ] Tests: collect output matches today's for in-view rows (order
      included); allocation-free warmed collect.
- [ ] Docs: `docs/rendering-assets-shaders.md` collect and capacities.

### Acceptance checks

- [ ] `render-game-prep-offview` meets its pass shape; `render-game-prep`
      shows no regression beyond run-to-run spread.
- [ ] `zig build gpu-smoke` on each available backend (display-gated).
- [ ] `zig build verify` passes.
