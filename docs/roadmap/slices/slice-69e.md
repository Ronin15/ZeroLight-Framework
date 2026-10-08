## Slice 69E: Per-Zoom Weather Spawn Rect

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md), [Slice 60](slice-60.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated** on the `particles-weather` and
`render-game-prep-weather` benches showing that weather emitted outside the
zoomed-in view is a measurable share of weather cost (owner call on the
measurement). Uses 69B's region-sampled emission and 70B's zoom tween when
landed.

Goal: at zoom levels above 1, weather spawns only over what the presentation
camera shows, with counts scaled by area so world-space density is the same
at every zoom, and zooming out never shows an empty band. Presentation only;
it never reads render-time state.

### Current foundation

- Slice 59 (not landed): weather emits over the player's `sim_view` plus a
  margin, from a fixed presentation seed, into a pool sized from the authored
  emitter table.
- Slice 60 (not landed): `CameraRig` keeps a fixed-step presentation center
  and integer zoom levels; 70B adds a fixed-step zoom tween.
- `systems/particle.zig` spawns always start at age 0.

### Architecture notes

- The spawn rect comes from the rig's fixed-step presentation state (center
  and visible extent, following 70B's tween when landed), never alpha, shake,
  or wall clock. At zoom 1 emission is bit-identical to Slice 59.
- Area scaling only lowers live counts (zoom ≥ 1), so Slice 59's derived pool
  capacity still bounds the pool; overflow drops stay counted
  (`.claude/rules/budgets-capacities.md`, presentation pool).
- A zoom-out prefills the newly visible band at steady-state density with
  particles at random ages and terminal velocity, under a fixed per-step
  count; draws use the presentation weather seed.

### Checklist

- [ ] Presentation view rect on the rig (tween-aware once 70B lands).
- [ ] Emitter rect selection by zoom, area-scaled counts.
- [ ] Particle spawns with an initial age (default 0, bit-identical).
- [ ] Zoom-out prefill.
- [ ] Docs: `docs/rendering-assets-shaders.md` (weather spawn rect per zoom).

### Acceptance checks

- [ ] Zoom 1 emission is bit-identical to the pre-slice baseline.
- [ ] Live particle density in the visible rect at zoom 4 matches zoom 1
      within ±10% over 600 steps.
- [ ] Zooming out from 4 to 1 during snow fills the new band to at least 70%
      of steady-state density on the first step.
- [ ] Emission, prefill, and pool update allocate nothing after reserve.
- [ ] `particles-weather` at zoom 4 records below its zoom-1 value.
- [ ] `zig build verify` passes.
