## Slice 23A: GPU Tilemap Render Hardening

Goal: harden Slice 23's retained GPU tilemap path for production digging and
multi-level compositing — correct depth ordering, safe partial tile uploads,
batched copy-pass staging, and pre-acquire CPU prep — without changing
simulation or `dig_controller` contracts.

Problem (observed on `expand2` before hardening):

- A linear `mergeDrawList` assumed static groups were pre-sorted by depth, but
  `submitStaticDenseGeometry` appended dense layers in storage order (surface
  first). That inverted underground compositing (grass/dirt flip, wrong plane
  visible through holes).
- Batched copy-pass staging passed `cycle=true` on the final upload when tile
  edits were the last work in the pass. Retained per-layer `GRAPHICS_STORAGE_READ`
  tile buffers require `cycle=false`; otherwise each dig ping-ponged GPU tile
  storage and flipped dirt/grass visually while CPU state stayed correct.
- Tile edits staged before swapchain acquire could be dropped on skipped frames
  when using clear-replace upload queues.

Current foundation (landed on `expand2`, runtime-validated):

- `mergeDrawList` stable-sorts static+dynamic groups by `RenderOrder` before
  coalescing; regression test covers unsorted underground dense depths.
- `submitStaticDenseGeometry` collects visible layers, sorts back-to-front by
  render depth at submit, and respects `active_level` (skip floors above the
  player). Re-submits on `dense_quads_dirty` or plane change only.
- `recordFrameCopyPass` batches dynamic vertices, optional static vertices, and
  tile edits in one copy pass; `uploadsRemainingCycle` counts **vertex** uploads
  only. Tile storage uses `recordStorageRegionsInPass` with **always
  `cycle=false`** and `MapGPUTransferBuffer(..., false)` for edit staging.
- `uploadTileDataEdits` appends pending edits (survives skipped frames); digs
  flush at the render boundary via `WorldSystem.flushDenseTileEdits`.
- Pre-acquire path: `prepareFrameCommands` / vertex staging before swapchain
  acquire; tile edits recorded after acquire in the frame copy pass (matches
  retained-buffer lifetime).
- `render_prep.submitGameplayFrame` owns layered world submit (static dense →
  tile-edit flush → sparse/dynamic z-walk); grow-only renderer reservations.

GPU upload `cycle` contract (do not regress):

| Resource | `cycle` on upload |
| --- | --- |
| Dynamic/static **vertex** ring streams | `true` on last vertex upload in the copy pass |
| **Tile-data storage** buffers (per-layer, retained) | **always `false`** |
| Tile-edit transfer buffer map | **`false`** |

Checklist:

- [x] Restore stable-sort `mergeDrawList` and add unsorted dense-layer regression
      test.
- [x] Sort dense layers back-to-front in `submitStaticDenseGeometry` before append.
- [x] Enforce `cycle=false` for all tile-storage uploads and tile-edit staging.
- [x] Exclude tile edits from vertex `uploadsRemainingCycle`; batch tile edits in
      the post-acquire copy pass.
- [x] Append pending tile edits across skipped frames; flush once per gameplay
      frame at the render boundary.
- [x] Keep dig/simulation ownership in `dig_controller` / `WorldSystem` CPU tile
      fields; render path consumes queued edits only.
- [x] Extend `render-game-prep` bench static depths to realistic underground
      stack order (`-2`, `-18`, `-34`).
- [ ] Land as a coherent commit stack on `expand2` and merge to `world`.
- [x] Document `cycle` rules in `docs/rendering-assets-shaders.md`.
- [ ] Optional: restore O(n) linear `mergeDrawList` now that submit-side sort is
      guaranteed (micro-opt; measure first).

Acceptance checks:

- [x] Dig hole/fall/ramp simulation tests pass unchanged (`dig_controller`,
      `game_demo_state`).
- [x] Visual layer stack correct: grass above dirt, carved tunnels show the plane
      below, no per-dig dirt/grass flip.
- [x] `zig build verify` passes.
- [x] `zig build gpu-smoke` exercises tilemap storage-buffer binds (`gpu_smoke_impl.zig`
      submits `appendStaticTilemapSpan` with retained tile-data buffer).

Status: landed on `expand2`; optional linear `mergeDrawList` micro-opt and
`expand2` → `world` merge remain backlog.


