## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (sprite-prep tuner), [Slice 85](../archive/slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: collect items landed. The backend and subsystem passes are done.**
Their unfixed findings are the open items below. Next is the GPU plan visiting the changed chunks.
Do not start slice 88 until those items are fixed or explicitly left.
`verify` passes. `gpu-smoke` passed on Vulkan only.

Goal: render collect work and its record and command capacity follow the
rows in the visible chunks, never the world's population. The GPU tile fill
is a stage and stays inline, because a worker dispatch costs more than the
copy. The renderer, sprite batch, text, and GPU buffers meet the cost model
and `.grok/rules/render.md` in the backend pass.

### Current foundation

- Collect walks each visible chunk's drawable run. Capacities follow those
  rows, the player marker, and the live particles.
- Each chunk owns its sparse rows. The window walk streams that run.
- Dynamic records are reordered once. Submit streams that order. Sparse emit
  streams its sorted columns.
- The GPU tile fill is a stage. The tuner keeps it inline.

### Architecture notes

- Render visibility is the camera chunk window plus AABB
  (`.grok/rules/render.md`). Collect cost follows what is visible
  (`.grok/rules/engine-design.md` § Cost model).
- The record and command capacities grow at the pre-reserve before the
  submission pass (`.grok/rules/memory-performance.md`). The GPU tile fill
  is a stage; the tuner keeps it inline.
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
- [x] GPU sync copying off main. The fill is a stage and the tuner keeps
      it inline: the copy is a short contiguous `u32` fill, and a worker
      dispatch costs more than it. Largest case, 32 layers, 118,528
      elements, 3 ranges. ReleaseFast, one rep: serial 149.6 µs, tuned
      99.2 µs inline, forced 2 workers 642 µs, forced pool 424 µs. Debug
      forced workers were also slower (2.63 ms and 1.82 ms against about
      1.5 ms inline). Do not force this copy onto workers.
- [x] Sparse tiles read as contiguous runs per (level, chunk). Each chunk
      holds its own row list; the last removal frees it. Debug, tree only,
      one rep, serial. Pan layouts at 1,000 / 16,000 / 256,000 tiles:
      chunk-ordered 188.8 / 191.0 / 173.4 µs, interleaved 180.3 / 177.0 /
      168.1 µs, churned 180.2 / 171.4 / 167.8 µs. The same 512 submissions
      at every size. Pass: the walk is flat in the world's sparse count, and
      the churned and interleaved layouts match the chunk-ordered one.
- [x] Render submit reads its records in sort order (contiguity audit M2).
      Dynamic records are reordered once and submit streams that order.
      Sparse emit streams its sorted columns. Debug, tree only, one rep,
      tuned versus serial: 817.8 µs versus 900.3 µs at 1,024; 3.59 ms versus
      3.95 ms at 4,096; 7.51 ms versus 8.84 ms at 10,000. Tuned used 23
      workers. The previous commit aborts in this bench, so there is no
      before.
- [x] Render backend pass. Camera, debug overlay, fps counter, resources,
      and the GPU helpers had no finding. The two findings are items below.
- [x] Subsystem pass. `render_depth.zig` matches its z contract. The GPU
      fill staying inline is the landed decision. The findings are items
      below.
- [x] Draw-list merge. `mergeDrawList` merges the two ordered streams,
      static wins an equal order, then coalesces. `appendStaticTilemapSpan`
      asserts nondecreasing order. Debug `render-game-prep` at 10,000 is
      within noise: serial 9.00 ms against 8.85 ms, tuned 7.59 ms against
      7.53 ms, 23 workers.
- [x] Sprite-prep lanes. Valid sprites are SoA columns. `writeSpriteLanes`
      is one lane path across sprites; the 6-vertex store stays the GPU
      layout. Debug `render-game-prep` at 10,000, one rep: tuned 7.59 ms
      to 7.94 ms (+4.6%), serial 9.00 ms to 9.88 ms (+9.8%), both within
      noise, 23 workers. Snapshot 368 µs to 729 µs. Tuned vertex emit
      380 µs to 314 µs.
- [x] Collect reads the drawable run only. Appearance columns live on
      the drawable run. `emitCollectedRow` reads that run. `refreshRunPose`
      stays pose-only. Debug `render-game-prep` at 10,000, one rep: tuned
      7.94 ms to 8.01 ms (+0.9%), serial 9.88 ms to 9.40 ms (-4.9%), both
      within noise, 23 workers. Tuned `entity_collect` 6.90 ms to 6.67 ms.
      Serial `entity_collect` 7.63 ms to 7.22 ms.
- [x] GPU plan visits the changed chunks. `markRenderChanged` records the
      changed chunk, and `GpuTileMirror.plan` walks that list. A one-chunk
      edit uploads that chunk and does not walk the other window chunks.
- [ ] Sparse window patch. One in-window sparse edit sets
      `sparse_window.dirty`, and the next
      `setVisibleChunksForWorldRect` (`src/game/world/render.zig:163`)
      recounts, refills, and sorts every window chunk. Failure scenario:
      one add or removal costs the whole window. Pass: the edited chunk's
      run is patched into the sorted window rows.
- [ ] Tier does not gate collect. `entityVisibleForRenderCollect`
      (`src/game/render_prep.zig:794`) is not called by collect. Failure
      scenario: skipping a dormant in-window row leaves the helper tests
      green. Pass: `collectDynamicRecords` emits an in-window dormant row
      and drops an out-of-window row, and the helper is gone.
- [ ] Dense layer order slices once. `denseLayerOrder`
      (`src/game/world/render.zig:793`) calls `dense_layers.slice()` on
      every comparison. Failure scenario: the sort rebuilds the column
      slices per compare. Pass: `collectDenseSubmitLayers` and
      `partitionDenseCompositeBuckets` slice once and pass the columns.
- [ ] Out-of-window player uses `drawable_slot`. Collect scans the chunk
      run for `player_row` (`src/game/render_prep.zig:515`) when the scope
      level is outside the render window. Failure scenario: that transition
      walks every row of the chunk. Pass: emit the row at `drawable_slot`.
- [x] Facing pointer lifetime. `facingPtr` and `directionPtr` are gone.
      Facing changes go through `setFacing`, which writes the drawable run.
- [x] The `render_game_prep` bench's module doc carries no review tags
      (`baa4e62`; `src/benchmarks/render_game_prep.zig:5-10` states what the
      group measures).
- [x] Tests: `render collect dynamic records follow the visible chunk`
      locks in-view rows, order, and the far row left out.
      `collect dynamic records after structural growth stays within reserve
      and allocates only on warmup` is the warmed `FailingAllocator` proof.
- [x] Docs: `docs/rendering-assets-shaders.md` collect and capacities, and
      `docs/architecture.md` per-chunk sparse runs.

### Acceptance checks

- [ ] `render-game-prep-offview` meets its pass shape (recorded on the
      collect item). `render-game-prep` runs on this tree (numbers on the
      submit item). The previous commit aborts in `render-game-prep`, so
      the regression comparison was not run.
- [ ] `zig build gpu-smoke` on each available backend (display-gated).
      Vulkan exited 0 (window, sprite, tilemap, upload growth, OOM reserve).
      No other backend was run.
- [x] `zig build verify` passes. The warmed `FailingAllocator` paths stay
      allocation-free: a level change uses the neighbor-level drawable run
      reserved when the visual is placed.
