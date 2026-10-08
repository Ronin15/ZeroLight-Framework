## Slice 59: Game Time, Day/Night Cycle, Seasons, And Weather

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md) (grade and weather visuals: [Slice 60](slice-60.md)) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 49 (session seed, `sim_view`). The scene
grade, weather draw, and lightning shake also need 60; the simulation side
(clock, calendar, weather, modifiers, events) does not. Slice 46 saves the
clock.

Goal: every world has a deterministic game clock advanced by the fixed step,
from which a calendar, seasons, a continuous day/night phase, and seeded
weather derive as pure functions of `(config, env_seed, game_ms)`, so saves
and replays need only the clock. Environment modifiers scale AI perception
range and AI move speed on sky-exposed levels for every agent at every
fidelity; weather particles, audio, and Slice 60's scene grade present the
observer's environment; low-volume transition events feed audio and camera.

### Current foundation

- `src/app/time_loop.zig`: 60 Hz fixed step (`fixed_delta_ns`,
  `fixed_delta_seconds`); `interpolationAlpha` is render-only.
- `systems/simulation_scope.zig` `step_count: u32` (Slice 49 makes it
  `StepIndex = u64`) is the canonical step; absolute-step schedules (56, 57,
  61, 62) use it, never calendar time.
- `src/core/rng.zig`: stateless `mix64` / `uniformF32` / `boundedU32` /
  `unitVec2` keyed by `(seed, index, step, salt)`. No `SeedDomain` exists
  until 49.
- Perception gather rows carry `vision_range`, `hearing_range`, and `level`
  per observer (`systems/perception.zig`); ranges are capped at validation
  (`data_system/perception.zig`).
- `MovementSystem.applyIntents` (`systems/movement.zig`) is a serial loop over
  merged intents using `body.speed`.
- `systems/particle.zig`: a fixed-capacity SoA pool, threaded SIMD update
  with `v += a*dt; p += v*dt`, no drag or wind; the demo pool is shared with
  destructible debris.
- Levels append only through `appendLevelBaseZ`; no sky-exposure fact exists
  (index 0 is the surface).
- `AudioCommandBuffer` looping SFX with an edge latch in
  `audio_controller.zig`; no rain, wind, or thunder assets exist.

### Architecture notes

- Owner direction: worlds keep advancing whether or not the observer is in
  them. The clock is per world instance and advances every step of that
  world; a world the observer is not in pays O(1) environment work per step
  (Slices 74, 75).
- Tint split: Slice 60 owns the GPU mechanism (`SceneGrade`, composite);
  this slice owns the pure environment → grade mapping in `src/game/`.
  The renderer knows nothing of time or weather (`.claude/rules/render.md`).
- The clock advances by an integer per step, never wall clock or frame
  count; paused gameplay runs no steps. Simulation-affecting outputs use
  integer math and IEEE basic ops only (`.claude/rules/simulation.md` §
  Determinism); trig feeds presentation only.
- Weather is a pure function of time and seed (no stored state), so any time
  skip lands on the weather stepping would reach. Weather rolls draw from
  `seed.derive(.environment)`; particle placement uses a fixed presentation
  seed (a Slice 49 exemption).
- Modifiers are identity at the default start and underground, and never
  exceed 1.0, so validated perception caps hold. Affect keeps base ranges.
  Player speed is unscaled (product decision).
- Sky exposure is a per-level fact set at the level-append seam; Slice 38
  derives it from elevation.
- One new stage at the front of `stage_order`; perception and AI movement
  read its resource (`.claude/rules/simulation.md` § Pipeline). Transition
  events are bounded per step and published as one range.
- Weather particles extend the existing particle system with drag and wind
  (no fork); a separate presentation pool sized from the authored emitter
  table, so weather never starves debris and overflow drops are counted
  (`.claude/rules/budgets-capacities.md`). Emission covers the observer's
  `sim_view`, never the render window.
- Persistent: the clock and sky exposure are hashed and saved; derived
  snapshots are excluded (Slices 49 / 46, same change).
- Out of scope: temperature (no consumer), scripted override (69D), time
  skip (69C), regional weather (69B), caution → affect (42).
- VoidLight: port the calendar, seasonal weather weights, modifier tables,
  and tint colors; do not port float/wall-clock time, thread-local RNG,
  string events, or per-frame non-dt drag.

### Checklist

- [ ] `math.smoothstep` core primitive with tests.
- [ ] Pure environment model: clock, calendar, seasons, day phase, weather
      rolls and blend, lightning, wind, modifiers, validated config.
- [ ] `SeedDomain.environment` (Slice 49 reserved value).
- [ ] Per-world clock and sky exposure on `WorldSystem`, reserved in
      lockstep with the level lists; Slice 49 / 46 classification and save.
- [ ] Environment stage, resource, and events (one range per step).
- [ ] Perception and AI movement read modifiers by level exposure.
- [ ] Particle drag and air velocity (scalar and SIMD); weather pool,
      emission over `sim_view`, pause resync.
- [ ] Weather render depth and draw path (needs 60).
- [ ] Environment → grade mapping and lightning shake (needs 60).
- [ ] Weather audio loops and thunder; stays open until authored audio files
      exist (no dead `AudioAssetId` tags).
- [ ] (added by Slice 67) Event-log arm for transitions; names as
      `StringId`s if this lands after 67E.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md` (stage, events),
      `docs/architecture.md` (environment ownership, per-world clock, tint
      split), `docs/rendering-assets-shaders.md` (weather pool and draw).

### Acceptance checks

- [ ] Pure tests: phase boundaries and daylight continuity in every season;
      deterministic weather per seed and time; zero-weight kinds never roll;
      N steps equal one jump; modifiers clamped, identity underground, 1.0 at
      the default start.
- [ ] Events: at most one per kind per step, one `day_started` for a
      multi-day jump, one range per step.
- [ ] Integration: a hostile at 0.7× range is perceived by day and not at
      night on the surface, and at night underground; AI move scale only on
      sky-exposed levels; causal-effect test that the environment applies
      before perception; perception serial == threaded with a non-identity
      lookup.
- [ ] Particles: scalar == SIMD with drag; `drag = 0` matches the pre-slice
      kernel; velocity converges to terminal; the weather pool never drops
      at the derived capacity.
- [ ] A world the observer is not in advances its clock and weather
      identically to the observed one (pure function of time).
- [ ] `FailingAllocator` proofs for the stage, emission, and render prep with
      a full weather pool.
- [ ] Determinism: same seed gives identical snapshots, events, and
      `simulationChecksum()` traces; a different seed changes weather.
- [ ] Benches `particles-weather` and `render-game-prep-weather`;
      `perception` shows no regression with identity lookup.
- [ ] Manual (with 60): day/night tint, drifting rain and snow that stop
      underground, lightning flash and shake.
- [ ] `zig build verify` passes.
