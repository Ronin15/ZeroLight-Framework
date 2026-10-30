## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (sprite-prep tuner), [Slice 85](../archive/slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: collect walk landed.** The visible-chunk runs, the two capacities,
and the off-view measure are in. Collect time and both capacities stay flat
as the off-view rows grow.
Routed by the 64G combined review (area C). The render backend pass closes
the core branch and comes after the collect moves, so the same files are
touched once; 88 follows the collect items, before the backend pass (index,
merged order).

Goal: render collect work and its record and command capacity follow the
rows in the visible chunks, never the world's population. The GPU tile sync's
per-change copying stays off the main thread. The renderer, sprite batch,
text, and GPU buffers meet the cost model and `.grok/rules/render.md`.

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
  (`.grok/rules/render.md`). Collect cost follows what is visible
  (`.grok/rules/engine-design.md` § Cost model).
- The record and command capacities grow at the pre-reserve before the
  submission pass (`.grok/rules/memory-performance.md`), and the GPU tile
  sync's byte copying threads (`.grok/rules/threading.md`).
- Render state and draw records are per world (`.grok/rules/render.md`);
  74 binds presentation to the viewed world.
- The backend pass is review-only (`zig-best-practices-review`), followed by
  local fixes.

### Checklist

- [x] Collect walks the visible chunks' rows. Debug, `437c8a1` against
      `6902aa9`, serial. Collect time 555.6 us, 533.8 us, and 511.5 us at
      4,096, 32,768, and 262,144 off-view rows. The base grows 308.5 us,
      1.21 ms, 8.09 ms. Record capacity stays 1,089 and command capacity
      stays 1,121. In view stays 1,024 and collected stays 1,088. At 4,096
      the window walk is slower than the old scan (555.6 us against 308.5
      us); from 32,768 it is faster. Failure scenario: off-view
      population raises frame cost and reserved vertex memory with nothing
      more drawn. The visible rows are scattered over the movement store
      (append and swap-remove order, `data_system/movement.zig:67`, `removeAt` `:189`), and
      collect resolves each row's level by slot (`render_prep.zig:388`)
      before its chunk test (`:395`). Constraint: the per-visible-chunk
      source reads each (level, chunk)'s rows as one contiguous run
      (contiguity audit H4; `.grok/rules/memory-performance.md`
      § Data-oriented design); the source is this slice's design.
      Measured: `render-game-prep-offview` above. Pass: collect time and the
      record and command capacities flat in off-view rows (group doc); the
      shape asserts land with the fix.
- [ ] GPU sync copying off main. The fill is a stage. Debug, tree only, one
      rep, 118,528 uploaded elements at 32 layers: serial-direct 1.42–1.62 ms
      on main, thread-fixed-2 2.63 ms (2 workers), thread-fixed-auto 1.82 ms
      (23 workers). The tuned case stayed inline. Pass not met: main still
      copies the bytes, and forcing workers is slower at this size.
- [x] Sparse tiles read as contiguous runs per (level, chunk). Each chunk
      holds its own row list; the last removal frees it. Debug, tree only,
      one rep, serial. Pan layouts at 1,000 / 16,000 / 256,000 tiles:
      chunk-ordered 188.8 / 191.0 / 173.4 µs, interleaved 180.3 / 177.0 /
      168.1 µs, churned 180.2 / 171.4 / 167.8 µs. The same 512 submissions
      at every size. Pass: the walk is flat in the world's sparse count, and
      the churned and interleaved layouts match the chunk-ordered one.
- [ ] Render submit reads its records in sort order (contiguity audit M2).
      Failure: `DynamicScenePrep` sorts an index array, `sort_indices`, by
      (depth, sequence) (`render_prep.zig:216`, sorted at `:266`), its comparator loading two
      records per compare (`:726-731`), and submit reads
      `records[record_index]` through it (`:270-271`); the sparse window sorts
      row ids over three pool columns (`world/render.zig:231`), and
      `emitSparseRange` (`:627`) reads each row by id
      (`.grok/rules/memory-performance.md` § Data-oriented design, § Hot
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
- [x] Docs: `docs/rendering-assets-shaders.md` collect and capacities, and
      `docs/architecture.md` per-chunk sparse runs.

### Acceptance checks

- [ ] `render-game-prep-offview` meets its pass shape; `render-game-prep`
      shows no regression beyond run-to-run spread (tuned-versus-control
      measured after slice 89's tuner change, which gets its own whole-suite
      run; the `750ce0a` baseline predates it).
- [ ] `zig build gpu-smoke` on each available backend (display-gated).
- [ ] `zig build verify` passes.
