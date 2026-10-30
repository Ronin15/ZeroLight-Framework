## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](../archive/slice-83.md) (sprite-prep tuner), [Slice 85](../archive/slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: collect items landed (`c6c066c` through `5011383`).** Still on
this slice: the backend pass, the subsystem pass, the `render-game-prep`
regression line, `gpu-smoke` on the other backends, and `verify`. Do not
start slice 88 until those are written up and fixed.

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
- [ ] `zig build verify` passes. Failed: 2038 pass, 7 fail. All seven are
      warmed `FailingAllocator` paths that now allocate in
      `reserveDrawableDestination` (`movement.zig`) from `setWorldLevel` →
      `retargetDrawable` during a level change of a body with a primitive
      visual. Idiom-lint was clean.
