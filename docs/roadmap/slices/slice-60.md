## Slice 60: Camera Behavior And Scene Composite Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 54](slice-54.md) (zoom setting), [Slice 70A](slice-70a.md) (index buffer, when landed) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 49 (`sim_view` contract) and 54 (zoom
persistence). Slice 59's grade and weather visuals consume `SceneGrade`; 44
binds pad zoom; 70B closes the deferred presentation items. After 52A, the
composite shader artifacts are regenerated and committed.

Goal: a deterministic fixed-step camera rig (follow lag, dead zone, catch-up,
world clamp that centers small worlds, integer zoom levels, seeded shake)
rendered through interpolation alpha as presentation only, whose zoom-1
anchor feeds Slice 49's `sim_view`; a renderer scene-texture plus composite
pass (world draws offscreen, composited with zoom, sub-pixel scroll in
`world_pixel` mode, and a color grade; UI and debug drawn after, untinted);
and an app-level fade-in on state replacement.

### Current foundation

- `src/render/camera.zig` `Camera2D { position, zoom }`; the renderer folds
  the camera into the `.world` vertex affine, so a pan uploads nothing.
- `game_demo_state.zig` steps `camera_previous` / `camera_current` in the
  fixed step, lerps them in `render`, and `cameraForPlayer` snaps to the
  player and clamps to the world (pinning to 0 when smaller).
  `simViewRect()` derives the simulation view from `camera_current`.
- `renderer.zig` `endFrame` runs one swapchain pass over the merged draw list;
  `mergeDrawList` sorts by domain then depth, so world groups are contiguous
  and first. Menus use the `.ui` domain.
- `src/app/state.zig` `TransitionApplyResult { quit_requested }`;
  `engine.zig` `applyTransitions`.
- `systems/spatial_index.zig` reserves a fixed dense window
  (`max_expected_visible_window_cells`, `max_dense_window_side_cells`)
  around the camera-derived region, assuming zoom 1.

### Architecture notes

- The rig is presentation state stepped in the fixed step; alpha, wall clock,
  and frame count enter only at render (`.claude/rules/render.md`).
- The simulation anchor is a pure function of the observer's target (the
  camera focus, or a player when present) and world bounds at the minimum
  zoom; no camera-feel term, zoom, shake, or alpha
  feeds it, so `sim_view` is invariant under presentation. It sets fidelity
  bands, never whether anything simulates (`.claude/rules/simulation.md` §
  Scope and tiers); the rendered view stays inside the full-fidelity band.
- Zoom levels are integers ≥ 1, so the visible area never exceeds the zoom-1
  window and render reservations are unchanged.
- Shake draws from a fixed presentation seed (a Slice 49 exemption).
- Game code only sets a `SceneGrade`; no SDL or GPU handle crosses the
  boundary. A neutral grade in `drawable` mode bypasses the composite, so
  menus and grade-free frames are byte-identical to today.
- The scene texture is fully re-rendered each frame (cycles); it grows only
  in the pre-acquire block from the drawable probe, never while holding the
  swapchain (`.claude/rules/render.md` § Frame and uploads).
- Fades are an app-level ordered UI rect above stacked states and below
  debug, not a composite term.
- Zoom actions are gameplay actions with pinned replay bits (Table T1);
  zoom index persists through Slice 54's settings (next schema version,
  Table T2).
- Spatial-index sizing is out of scope here: 75 owns spatial-index coverage
  of the whole population, not a window around the camera.
- Out of scope: rotation, free/fixed modes (no consumer); zoom tween,
  runtime scene mode, fade-out, sharp-bilinear (70B).
- VoidLight: port follow lag, dead zone, catch-up, clamp, integer zoom, shake
  as decaying offset, and the scene + composite pass; do not port its
  unseeded shake RNG, global camera events, `cycle=false` targets, or
  per-resize recreation.

### Checklist

- [ ] `math.expSmoothingFactor` with tests.
- [ ] `CameraRig` with the separate simulation anchor; replaces the demo's
      camera fields and `cameraForPlayer`.
- [ ] Zoom actions, bindings, routing tests, replay bits (Table T1).
- [ ] `simViewRect()` returns the rig's anchor.
- [ ] Zoom setting on 54's store (schema live + 1).
- [ ] Trauma from destructible destroys (and 59's lightning).
- [ ] Scene composite: modes, grade, params layout, shaders and committed
      artifacts, scene target, composite pipeline, two-pass `endFrame`
      (binding 70A's index buffer per pass when landed), neutral bypass.
- [ ] Screen fade-in on replace with its command headroom.
- [ ] `scene_resolution` app config and build option.
- [ ] `gpu-smoke`: both modes, a regrow, UI and debug after the composite.
- [ ] (added by Slice 64) Pause does not resync the rig (64A alpha hold).
- [ ] (added by Slice 67) Strings as `StringId`s if this lands after 67E.
- [ ] Docs: `docs/rendering-assets-shaders.md` (composite, modes, cycle row,
      fade order), `docs/architecture.md` (rig and anchor ownership),
      `docs/state-stack-and-input.md` (zoom, fade),
      `docs/development-workflow.md` (`-Dscene-resolution`).

### Acceptance checks

- [ ] Rig: lag 0 reproduces the old camera (centering replaces pin-to-0 for
      small worlds); follow, dead zone, catch-up, clamp, zoom bounds, shake
      determinism and decay.
- [ ] The anchor is bit-identical across zoom index, trauma, alpha, and lag,
      including at world edges, and equals the pre-slice `simViewRect()` on
      worlds at least as large as the view.
- [ ] Composite: layout and transform math for both modes; a world point maps
      to the same output pixel through either path (exact in `drawable`,
      within half a texel × zoom in `world_pixel`); grow-only sizing.
- [ ] Neutral `drawable` frames take the pre-slice path; existing
      `FailingAllocator` proofs pass and cover the fade rect.
- [ ] `zig build gpu-smoke` passes both modes with validation clean.
- [ ] Manual: lagged follow without shimmer, zoom snaps, shake, pixel-perfect
      scroll, untinted UI, fade-in.
- [ ] `render-game-prep` bench shows no regression; Slice 49's
      render-window-independence test still passes.
- [ ] `zig build verify` passes.
