## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](slice-83.md) (sprite-prep tuner), [Slice 85](slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Routed by the 64G combined review (area C). The
render backend pass closes the core branch and comes after the collect moves,
so the same files are touched once. Owner question (index, docs audit M5):
88 depends on 87 and runs before the branch's last items, so 87 cannot be
complete before 88 starts while its backend pass closes the branch.

Goal: render collect work and its record and command capacity follow the
rows in the visible chunks, never the world's population. The GPU tile sync's
per-change copying stays off the main thread. The renderer, sprite batch,
text, and GPU buffers meet the cost model and `.claude/rules/render.md`.

### Current foundation

- `render_prep.collectDynamicRecords` (`src/game/render_prep.zig:374`) walks
  every movement body (`:397`) on main each frame. For each row it tests the
  level window and the visible chunks.
- `dynamicRecordCapacity` (`:314`) and `spriteCommandCapacity` (`:323`) size
  to every primitive visual in the world.
- GPU tile sync: `GpuTileMirror.plan` and `commit`
  (`src/game/world/gpu_tiles.zig:265`, `:445`) copy a batched change's
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
      (append and swap-remove order, `data_system/movement.zig:168`), and
      collect resolves each row's level by slot (`render_prep.zig:400`)
      before its chunk test (`:406`). Constraint (contiguity audit H4): the
      per-visible-chunk source reads each (level, chunk)'s rows as one
      contiguous run, from 84's index if 75 indexes the whole population or
      from a chunk-owned row block; an intrusive per-chunk list fails the
      same rule (`.claude/rules/memory-performance.md` § Dense SoA storage).
      Measured: `render-game-prep-offview` above. Pass: collect time and the
      record and command capacities flat in off-view rows (group doc); the
      shape asserts land with the fix.
- [ ] GPU sync copying off main. Failure scenario: an explosion's batched
      change costs main time linear in the bytes it wrote. Measured: about
      2 ms for 32 layers. Pass: main keeps only the ordered upload commit;
      serial == threaded; `chunk-scale-gpu-sync-dig` gains threaded cases.
- [ ] Sparse tiles read as contiguous runs per (level, chunk) (contiguity
      audit M1). Failure: `sparse_tiles` (`world/system.zig:280`) links its
      rows newest-first per (level, chunk) through `chunk_next` and
      `chunk_prev` (`:191-192`) over one world-wide pool, and
      `walkWindowSparseTiles` (`world/render.zig:177`) walks each window
      chunk's list, reading `cell_index` from scattered pool rows. Failure
      scenario: while panning, every tile-edge crossing walks fragments, more
      scattered after dig and build churn. Medium: bounded by the window, and
      idle while the camera is still. Pass: the window walk reads each
      chunk's sparse rows as one contiguous run; a churned
      `render-sparse-window-pan` case matches the unchurned one.
- [ ] Render submit reads records in sort order (contiguity audit M2).
      Failure: `DynamicScenePrep` sorts `sort_indices` by (depth, sequence)
      (`render_prep.zig:278`, a comparator loading two records per compare at
      `:739-740`), and submit gathers `records[record_index]` (`:527-530`);
      the sparse window sorts row ids over three pool columns
      (`world/render.zig:230`), and `emitSparseRange` gathers per id
      (`:626`). Failure scenario: every frame reads the visible records out
      of order. Medium: the count is the visible records, each feeding one
      renderer call. Pass: submit walks its records (or a packed key array
      carrying the payload) in memory order; `render-game-prep` within
      spread or faster.
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
- [ ] The `render_game_prep` bench's module doc carries review tags
      "(R29/R32)" (`src/benchmarks/render_game_prep.zig:5`) (code audit L9;
      `.claude/rules/zig-style.md` § Comments). Pass: the doc states what the
      group measures, with no tags.
- [ ] Tests: collect output matches today's for in-view rows (order
      included); allocation-free warmed collect.
- [ ] Docs: `docs/rendering-assets-shaders.md` collect and capacities.

### Acceptance checks

- [ ] `render-game-prep-offview` meets its pass shape; `render-game-prep`
      shows no regression beyond run-to-run spread.
- [ ] `zig build gpu-smoke` on each available backend (display-gated).
- [ ] `zig build verify` passes.
