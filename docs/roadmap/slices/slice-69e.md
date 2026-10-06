## Slice 69E: Per-Zoom Weather Spawn Rect

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md), [Slice 60](slice-60.md) (gated on weather cost > 0.25 ms) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated.** Gate: in ReleaseFast, the sum of the median
weather cost per step exceeds **0.25 ms** (1.5% of the 16.67 ms frame). The
weather cost is `zig build bench -- --group particles-weather` (2048 items,
drag + wind) plus `zig build bench -- --group render-game-prep-weather` (full
pool). The measurement is taken on the machine that records Slice 59's bench
baseline. Depends on **59** and **60** (`CameraRig`), and on **69B**'s
region-sampled emission if landed.

Goal: at zoom levels above 1, weather spawns only over what the presentation
camera shows. The emitted count scales by area, so world-space density is
unchanged at every zoom. Zooming out never shows an empty band. It stays
presentation-only and never reads render-time state.

### Architecture notes

**Spawn rect.**

- `CameraRig.presentationViewRect() Rect` returns
  `{ center_current - view_size/(2z), view_size/z }` with
  `z = zoom_levels[zoom_index]`. Once Slice 70B has landed (it lands earlier
  in the merged order), the extent is 70B's fixed-step tweened visible extent
  instead: `{ center_current - view_size·zoom_inv_current/2,
  view_size·zoom_inv_current }`. That state advances in `step` regardless of
  the render mode, so the spawn rect follows the zoom tween instead of
  jumping to the target, and it equals the `1/z` form when settled. It is the
  fixed-step, already-clamped presentation center: no alpha, no shake, no
  wall clock.
- At zoom index 0 (and, with 70B, a settled tween) the emitter keeps
  `simViewRect()` (the zoom-1 anchor), which is Slice 59's behavior, bit for
  bit. Otherwise, including a tween still running toward index 0, it uses
  `presentationViewRect()`.
- Both rects are expanded by `k_weather_spawn_margin_px = 96`, Slice 59's
  value.

**Area-scaled count.**

- `area_scale = area(rect + margin) / area(anchorRect() + margin)`, computed
  in f32 on the presentation side.
- Per kind, `n = floor(share * max_emit * area_scale + u)`, with the same dither
  stream as Slice 59. 69B's acceptance draw is unchanged.

**Zoom-out prefill.**

- On the fixed step where `captureZoomInput` lowers the zoom index,
  `EnvironmentController.prefillWeatherParticles(pool, new_rect, old_rect,
  ...)` emits per kind
  `n = floor(steady_live(K) * (1 - area_old/area_new) + u)`, where
  `steady_live(K) = share * max_emit * lifetime_steps(K) * area_scale_new`.
- Positions are uniform over `new_rect`. A point inside `old_rect` is rejected,
  with up to `k_prefill_attempts = 4` attempts per particle before it is
  dropped.
- `ParticleSpawn` gains `initial_age: f32 = 0`, validated to
  `0 <= initial_age < lifetime`; `spawnToRow` sets `age = initial_age`. The
  prefill draws `initial_age` uniformly in `[0, lifetime)` and sets velocity to
  the terminal `air + a/drag`.
- Draws come from `k_weather_particle_seed` under salt
  `k_environment_salt_base + 0x500 + i`, part of Slice 49's weather-particle
  exemption.
- The prefill is bounded by `k_weather_prefill_max_per_step = 1024` and by the
  2048 pool. Drops are counted.

**Fixed budgets.**

- `k_weather_prefill_max_per_step = 1024`: the worst steady-state fill is
  storm 864 / snow 1080 × 3/4 of the area.
- `k_prefill_attempts = 4`.
- Pool capacity is unchanged at 2048.

### Checklist

- [ ] `CameraRig.presentationViewRect()`, with tests that it is invariant under
      alpha and trauma and clamped like the center, and (with 70B) that it
      tracks `zoom_inv_current` through a tween rather than the target index
      and equals the `1/z` form once settled.
- [ ] Emitter rect selection by zoom index, and area-scaled counts.
- [ ] `ParticleSpawn.initial_age` with validation. Existing spawns default to
      0 and stay bit-identical.
- [ ] `prefillWeatherParticles`, triggered on a zoom-out edge.
- [ ] Docs: `docs/rendering-assets-shaders.md` (weather spawn rect per zoom).

### Acceptance checks

- [ ] At zoom index 0, emission is bit-identical to the pre-slice baseline.
- [ ] World-space density (live particles per world px² inside the visible
      rect, over 600 steps) at zoom 4 matches zoom 1 within ±10%.
- [ ] Zooming out from 4 to 1 during snow: the newly visible band reaches at
      least 70% of steady-state density on the first step.
- [ ] Emission, prefill and pool update allocate nothing after reserve
      (`FailingAllocator`).
- [ ] The gate metric drops: `particles-weather` at zoom 4 is recorded below
      the zoom-1 value.
- [ ] `zig build verify` passes.

