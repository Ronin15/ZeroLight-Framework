## Slice 70B: Presentation Polish (Runtime Scene Resolution, Pad Zoom, Fade-Out, Sharp-Bilinear, Zoom Tween)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 60](slice-60.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 60 (camera rig, composite, scene modes, fade-in,
zoom actions and setting), 54 (settings store, video settings, live apply,
`choice` widget), and 44 (pad inputs, runtime bindings, Controls screen). The
composite shader changes, so its committed artifacts are regenerated (52A).
The trigger moves apply to `attack` (56) and `use_item` (57) if they have
landed.

Goal:

1. Scene resolution (`drawable` / `world_pixel`) is a persisted video setting
   applied live through a cold renderer re-layout, and a persisted choice
   never bricks startup on a GPU that lacks support.
2. The zoom actions get default pad bindings in one final stick-click and
   trigger layout, with existing settings files migrated, never rejected.
3. A replace batch fades to black before the swap, with the outgoing stack
   frozen and quit never delayed.
4. `world_pixel` shows no texel-width shimmer at non-integer magnification
   (sharp-bilinear sampling); integer magnification keeps exact nearest.
5. Zoom changes tween over a fixed number of steps in drawable mode.

None of this touches the simulation anchor, `sim_view`, or the checksum.

### Current foundation

- `src/app/engine.zig`: `handleEvents` → state events → `applyTransitions`;
  `applyFrameControls`; `update` runs states then transitions and audio;
  `renderFrame` feeds `interpolation_alpha`.
- `src/app/state.zig`: `StateTransitions` FIFO (`replace`, `push`, `remove`,
  `pop`, `quit`); `replace` destroys the whole stack;
  `TransitionApplyResult { quit_requested }`.
- `src/main.zig` fixed loop over `time_loop.shouldUpdate()` (at most 5 updates
  per frame), then `renderFrame`.
- `src/app/input.zig` `default_gamepad_bindings` maps face buttons, start,
  back, D-pad, and shoulders; stick clicks are unbound today.
- `src/app/resolution.zig`: `integer_fit` gives exact integer scales; `fit`,
  `stretch`, and `overscan` do not.
- `src/render/gpu/device.zig`: one nearest clamp-to-edge sampler.
- Slices 60, 54, and 44 (not landed) provide the rig, composite, fade-in,
  settings chain, and pad binding model this slice extends. Interim pad
  defaults: 56 puts `attack` on R3 and 57 puts `use_item` on L3.

### Architecture notes

- Settings bump live + 1 with one upgrade step (Table T2); the build option
  stays the default. A runtime-only preference keeps the user's stored
  choice when startup falls back, so one launch on an unsupported GPU never
  overwrites it; a user edit wins.
- The re-layout is cold and main-thread, never inside a frame; it touches only
  the scene target (`.claude/rules/render.md`).
- Pad defaults keep one action per input; replay bits record actions, so no
  replay change (Table T1). Migration moves old trigger defaults before
  filling zoom, and an explicit user binding always beats a default fill.
- The fade-out hold freezes the outgoing stack: no updates, events to states,
  or pause while holding; the accumulator is drained so no catch-up burst
  reaches the new state; the swap applies after the fade completes. It is
  presentation only and runs no simulation steps, like pause
  (`.claude/rules/input-state.md`). Every replace fades; quit applies
  immediately.
- Sharp-bilinear is selected purely from mode, viewport scale, and zoom; it
  adds one sampler and one composite parameter vector, keeping the exact
  pass-through when grading and sharpening are off.
- The zoom tween is fixed-step rig state over the visible extent (no
  transcendental), rendered only in drawable mode; the simulation anchor and
  render reservations are unchanged (zoom stays ≥ 1).
- Out of scope, by decision: tween in `world_pixel`, non-black fades, audio
  crossfades, instancing (70A).
- VoidLight: port fade transitions with a duration, the composite-uniform
  pattern, and integer zoom endpoints; do not port its 1 s default, global
  event dispatch, top-left `uv / zoom`, or fast-math filtering.

### Checklist

- [ ] Scene resolution setting (schema live + 1), renderer query / supported
      / set, unconditional composite and sampler creation, startup fallback
      with the stored-preference rule, live apply with revert, "Pixel mode"
      choice row.
- [ ] Pad layout: R3/L3 zoom, RT/LT for `attack` / `use_item` where present;
      ordered migration; explicit-beats-default-fill in 44's loader.
- [ ] Fade-out hold: pending-transition classification, fade phases, the
      transition gate, and engine glue (events, frame controls, update,
      render with held alpha).
- [ ] Sharp-bilinear selection, composite parameter growth, shader branch,
      linear sampler, `world_pixel` coverage, regenerated artifacts.
- [ ] Zoom tween: `math.easeOutCubic`, rig tween state, render mode by scene
      resolution.
- [ ] (added by Slice 67) 67C's thumbnail probe runs in both scene modes.
- [ ] `gpu-smoke`: drawable graded, `world_pixel` sharp, integer-fit nearest,
      back to drawable.
- [ ] Cross-slice text in 60, 44, 56, 57, 67C, and 69E points to this slice
      for the moved items, in the same change.
- [ ] Docs: `docs/rendering-assets-shaders.md`, `docs/state-stack-and-input.md`,
      `docs/architecture.md`, `docs/development-workflow.md`.
- [ ] Add the explicit-beats-default-fill rule to
      `.claude/rules/input-state.md` when this lands.

### Acceptance checks

- [ ] Settings: the previous version upgrades preserving every field; the
      preference survives a fallback and an unrelated save; a live-apply
      failure reverts.
- [ ] Migration: a pre-70B file with old-default R3/L3 ends with triggers on
      `attack` / `use_item` and stick clicks on zoom; a customized binding is
      kept; a colliding default becomes empty, never a rejection.
- [ ] Fade gate: apply, hold until complete, release, quit bypass, no
      re-entry while holding; fade alpha continuous from a mid fade-in.
- [ ] Sharp-bilinear: drawable and integer magnification take nearest; a
      non-integer fit takes sharp; the CPU reference matches the shader math.
- [ ] Zoom tween: settled frames equal 60's integer zoom; the tween reaches
      the target exactly and stays inside world bounds; the anchor is
      bit-identical with tween on and off.
- [ ] `zig build gpu-smoke` passes all four frames with validation clean.
- [ ] Manual: live Pixel-mode switch persists across restart; no shimmer under
      Fit; pad zoom and trigger actions; fade-out, swap, fade-in; tween in
      Smooth, snap in Pixel-perfect; UI untinted.
- [ ] `render-game-prep` bench recorded before and after with no regression.
- [ ] `zig build verify` passes (stale-lock gate with regenerated artifacts).
