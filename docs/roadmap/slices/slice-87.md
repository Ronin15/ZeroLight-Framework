## Slice 87: Render Collect By Visible Chunks

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](slice-83.md) (sprite-prep tuner), [Slice 85](slice-85.md) and [Slice 35](slice-35.md)'s `world_gate` items (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** Routed by the 64G combined review (area C). The
render backend pass closes the core branch and comes after the collect moves,
so the same files are touched once.

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
- Render storage grows only at the main-thread pre-reserve before the
  submission pass (`.claude/rules/memory-performance.md`). Copying bytes is
  per-item work that grows, so it threads (`.claude/rules/threading.md`).
- Render state and draw records are per world (`.claude/rules/render.md`);
  74 binds presentation to the viewed world.
- The backend pass is review-only (`zig-best-practices-review`), followed by
  local fixes.

### Checklist

- [ ] Collect walks the visible chunks' rows. Failure scenario: off-view
      population raises frame cost and reserved vertex memory with nothing
      more drawn. Measured: `render-game-prep-offview` above. Pass: collect
      time and the record and command capacities flat in off-view rows
      (group doc); the shape asserts land with the fix.
- [ ] GPU sync copying off main. Failure scenario: an explosion's batched
      change costs main time linear in the bytes it wrote. Measured: about
      2 ms for 32 layers. Pass: main keeps only the ordered upload commit;
      serial == threaded; `chunk-scale-gpu-sync-dig` gains threaded cases.
- [ ] Render backend pass, last on the core branch: the renderer, sprite
      batch, text, and GPU buffers against the cost model and `render.md`;
      local fixes land here, and structural findings become items here.
- [ ] Tests: collect output matches today's for in-view rows (order
      included); allocation-free warmed collect.
- [ ] Docs: `docs/rendering-assets-shaders.md` collect and capacities.

### Acceptance checks

- [ ] `render-game-prep-offview` meets its pass shape; `render-game-prep`
      shows no regression beyond run-to-run spread.
- [ ] `zig build gpu-smoke` on each available backend (display-gated).
- [ ] `zig build verify` passes.
