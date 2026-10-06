## Slice 23B: Multi-Depth Dense-Layer Render Scaling

Goal: make the Slice 23A retained tilemap path scale to large vertical worlds
(~120 depth levels, more entities) without linear draw-count and memory blow-up
at the surface, while preserving the 23A GPU upload invariants.

Problem (current envelope):

- One draw + one full-world storage buffer per **submitted** dense layer. At
  `active_level = 0` every layer at or below the player is submitted — for 120
  floors that is 120 draws and ~120 MB GPU tile data at 512² (manageable on
  desktop, wrong policy for steady-state frame cost).
- `k_max_dense_submit_layers = 16` in `world_system.zig` hard-fails beyond 16
  visible dense layers — blocks the first content expansion.
- `mergeDrawList` is O(n log n) in group count; acceptable at a bounded window,
  not at 120+ static groups every frame at the surface.
- Entity render prep already scales via SoA collect + `spriteCommandCapacity`;
  dense floors are the primary new cost — not per-tile vertex streaming.

Architecture notes:

- Simulation and nav already support multi-level worlds (Slice 25 per-level grids,
  `LevelLink`, incremental rebuild). This slice is **render visibility policy**
  only — no dig logic or nav contract changes.
- Slice 24 cube LOD already demotes off-level / far entities on the **sim**
  axis; 23B is the matching **render** axis for dense floor layers.
- Slice 25E adds per-entity depth alignment and entity render cull; dense-floor
  window policy stays in `WorldSystem` / `render_prep`.
- Chunked or streaming tilemaps are out of scope here unless profiling forces
  them; prefer a vertical **render window** first.

Recommended policy (default unless gameplay disproves it):

- Submit dense layers only in `[active_level .. active_level + N]` (N tuned to
  visible stack depth, e.g. 4–8) plus any layers required for surface-hole
  see-through (at most one ceiling band above the player when standing on
  level 0).
- Size `k_max_dense_submit_layers`, `reserveStaticGeometry`, and
  `draw_list_high_water` from the chosen window — not from total world depth.
- Pre-size GPU tile-data buffers for all authored dense layers at load (memory
  is level-count × cell count); culling affects **draw/submit** only unless a
  later slice adds buffer residency policy.

Current foundation (landed):

- `DenseLayerRenderWindow` in `world_system.zig`: default `levels_below = 6`,
  `ceiling_when_underground = false` (render slice follows `player_level` /
  `active_level`; surface hole see-through uses the below window at level 0).
  Optional `ceiling_when_underground` redraws one level above when enabled.
  `levelInWindow` gates submit;
  `maxSubmitLayers` sizes the window from per-level dense-band cap.
- `maxDenseSubmitLayerCount`, `validateDenseRenderBudget`, and
  `collectDenseSubmitLayers` replace the demo-only 16-layer hard cap;
  `k_max_dense_submit_stack_cap = 32` is a defensive submit-time guard.
  `WorldBuildConfig.render_window` and optional `max_dense_tile_gpu_bytes`
  fail loud at world build (`initDemo` / `initProcedural`).
- `submitStaticDenseGeometry` collects only in-window layers, sorts
  back-to-front, and re-submits on `dense_quads_dirty`, `active_level`, or
  window change. `GameplayScene.player_level` drives the handoff.
- `render_prep.ensureStaticGeometryCapacity` reserves static geometry from
  `WorldSystem.maxDenseSubmitLayerCount()` at the start of `submitGameplayFrame`
  (grow-only; allocation-free after the first reserve).
- `render-game-prep` dense surface (`player_level = 0`) and deep
  (`player_level = 40`) benchmark groups (Slice 36 collapsed the original
  8/16/32 tilemap-group-count variants once that parameter stopped varying
  the fixture); unit tests cover window caps, player level transitions,
  per-band inclusion, and depth order.

Checklist:

- [x] Define `DenseLayerRenderWindow` policy (min/max level offset, hole/ceiling
      exception rules) and document it beside `submitStaticDenseGeometry`.
- [x] Replace demo-only `k_max_dense_submit_layers = 16` with window-derived cap
      (or explicit world-build budget) and fail loud at world build if exceeded.
- [x] Wire window into `submitStaticDenseGeometry` and
      `GameplayScene.player_level` / camera-level handoff.
- [x] Reserve renderer static-group high-water from window + sparse overhead.
- [x] Add `render-game-prep` bench cases at `player_level` 0 vs mid-depth;
      record `mergeDrawList` and submit cost (originally also varied at
      8/16/32 static tilemap groups; that axis was collapsed in Slice 36 once
      it stopped affecting the built fixture).
- [x] Add unit tests: surface window caps submit count; deep play submits only
      the near stack; depth order preserved within the window.
- [x] Profile GPU memory budget for target level count × world size; document
      ceiling in `WorldBuildConfig` or load-time gate.
- [ ] Optional: restore linear `mergeDrawList` after window sort guarantees
      static order.

Deferred (separate slice if window is insufficient):

- Chunk-aligned dense tilemap regions instead of one full-world quad per layer.
- Level-of-detail / clip planes for deep underground beyond the window.
- Tile-data buffer unload for layers far from play (residency policy).

Acceptance checks:

- [x] World build with ≥32 dense levels succeeds; surface play stays within the
      configured draw and submit budget.
- [x] Digging through a vertical stack at depth 0..N shows correct planes in the
      window; no 23A regressions (depth order, `cycle=false`).
- [x] `zig build bench -- --group render-game-prep` reports stable prep cost at
      configured window sizes.
- [x] `zig build verify` passes.

Status: implemented and runtime-validated; window policy documented in
`docs/rendering-assets-shaders.md`. Optional linear `mergeDrawList` micro-opt
remains open.


