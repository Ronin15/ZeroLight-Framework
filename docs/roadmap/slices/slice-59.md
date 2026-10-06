## Slice 59: Game Time, Day/Night Cycle, Seasons, And Weather

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **Slice 49**: the weather and lightning stream
seed is `env_seed = seed.derive(.environment)` (this slice appends
`SeedDomain.environment = 6`), and the weather spawn rect is Slice 49's
`GameDemoState.simViewRect()`. The checklist items that produce the scene grade and
weather visuals also depend on **Slice 60** (`SceneGrade`, `Renderer.setSceneGrade`,
the composite pass, and `CameraRig.addTrauma`). The sim side (clock, calendar, weather,
modifiers, events) does not depend on 60. Slice 46 must round-trip `WorldSystem.clock`
(Slice 64 addition (b), folded into [Slice 46](slice-46.md)).

Goal: give each world a deterministic game clock derived from the fixed step. Derive
from it a calendar, seasons, a continuous day/night phase, and a seeded weather state
machine. Feed the result into AI perception range and AI move speed. Drive weather
particles (wind, drag, terminal velocity) on the existing particle system. Publish
low-volume environment transition events for audio and camera reactions. Then map the
environment to Slice 60's scene grade (day/night tint, weather haze, desaturation,
lightning flash). Every environment value is a pure function of
`(EnvironmentConfig, env_seed, game_ms)`, so save/load and replays need only the
clock (the seed root is already in the Slice 49 header).

### Current foundation (do not rebuild)

- `src/app/time_loop.zig:8-11` sets the fixed step: 60 Hz, `fixed_delta_ns`,
  `fixed_delta_seconds`. `interpolationAlpha` (`:58-61`) is render-only.
- `src/game/systems/simulation_scope.zig:99,168,181` has `step_count`, which Slice 49
  types as `StepIndex = u64` (Slices 68A–68C addition). It is the canonical persisted
  simulation step: it is in the Slice 49 checksum header, and Slice 46 persists it.
  Absolute-step schedules use it (56 `next_attack_step`, 57 `despawn_step`, 61
  `regrow_at_step`, 62 `next_eligible_step`). It is not calendar time. Calendar, day
  phase, season, and weather read `WorldSystem.clock.game_ms`.
  - `step_count += 1` (`:168`) is a plain add on a `u64`: 2^64 steps at 60 Hz is
    about 9.7 billion years, so there is no practical horizon. Every absolute-step
    write goes through Slice 56's `simulation_scope.stepAfter(now, delta)`
    (saturating) and every comparison through `stepReached(now, due)`.
  - Any **step-derived product** (for example a sweep cursor
    `step * budget % len`) is computed directly in `StepIndex`; it overflows only
    after 2^64 / budget steps.
- `src/core/rng.zig:20-56` provides the stateless `mix64` / `uniformF32` / `boundedU32` /
  `unitVec2` keyed by `(seed, entity_index, step, salt)`. The only salt in use today is
  `ai.zig:293` `wander_rng_salt = 0`.
- `src/game/simulation_pipeline.zig:86-120` (`PipelineResource`), `:128-148`
  (`StageId`), `:161` (`external_resources`), `:167-231` (`stageContract`), `:262-282`
  (`stage_order`) and `:1015-1037` (`runStage`) form the comptime-checked stage graph.
  Perception (`:179`) and `apply_ai_movement_intents` (`:198`) are the two consumers
  this slice adds a read to.
- `src/game/simulation.zig:48-70` defines `EventProducerId` and the exhaustive
  `maxEventsPerStep`. `:153-164` is the scalar-only `SimulationEventPayload` union.
  `game_demo_state.zig:156-159` sums the per-step `event_reserve`.
- `src/game/systems/perception.zig:274-299` defines `PerceptionGatherRow`, which
  carries `vision_range`, `hearing_range` and `level` per observer. `computeOneAgent`
  (`:1494-1611`) uses them for the spatial scan radius, the player range check and the
  hearing range. `data_system/perception.zig:15-27` caps both ranges at validation.
  `los_max_cells` (`perception.zig:153`) is sized from that cap.
- `src/game/systems/movement.zig:59-71` (`applyIntents`) is a serial loop over merged
  movement intents. It already resolves each entity's body. Speed is `body.speed` or the
  default.
- `src/game/systems/particle.zig` is a fixed-capacity MAL SoA pool (`ParticleRow`
  `:168-195`). Emission is best-effort (`emit` `:330-339`). The update kernel is
  threaded SIMD plus a scalar tail (`processRange` `:483-545`, scalar `:556-575`) with
  `v += a*dt; p += v*dt`. There is no drag and no wind. The demo pool is 512 rows
  (`game_demo_state.zig:410`) and is shared with destructible debris
  (`destructible_controller.zig:330`).
- `src/game/render_prep.zig:483-494` collects particles into dynamic records with a
  camera AABB cull. `finalizeDepthBuckets` (`:275-307`) comparison-sorts every dynamic
  record. `render_depth.zig:7-13` defines `WorldDepth` (`floor`..`marker`).
- `src/game/world_system.zig:1607-1613` (`appendLevelBaseZ`) is the single level-append
  choke point. It reserves and appends only `level_base_z`. `addUndergroundLevelStack`
  (`:1676`) calls it after pre-reserving only `level_base_z` (`:1679`).
- `startLoopingSfx` / `stopLoopingSfx` are `AudioCommandBuffer` methods
  (`src/app/audio.zig:132-139`). `src/game/audio_controller.zig` holds the edge latch
  (`:5-45`, `:60-90`; `LoopingSfxId` 1 = jet). `assets/manifest.zig:14-18` defines
  `AudioAssetId`. No rain, wind or thunder assets exist.
- `src/game/simulation.zig:341-351` (`appendRequired`) writes one record and calls
  `finishWrite` per call, which rebuilds stats over all ranges each time.
- `game_demo_state.zig:615-619` (`syncInterpolatedState`) resyncs pipeline positions,
  the debris particle pool, and the camera on pause/resume.

### Architecture notes

**Tint ownership (decision).** The GPU mechanism belongs to **Slice 60**: the
`SceneGrade` type, the composite uniform layout, the shader, and
`Renderer.setSceneGrade`. The mapping from environment to grade belongs here, in the
game-side pure module `src/game/environment_grade.zig`. The renderer knows nothing about
time or weather. The game knows nothing about GPU layouts.

**Owners and new modules.**

- `src/game/environment.zig` holds the pure model. It has no allocator and no state
  beyond value types: `WorldClock`, `Season`, `DayPhase`, `WeatherKind`,
  `EnvironmentConfig` plus its tables, `EnvironmentSnapshot`, `EnvironmentModifiers`,
  `EnvironmentModifierLookup`, `deriveSnapshot(config, env_seed, game_ms)`, and the salts.
- `src/game/environment_controller.zig` holds `EnvironmentController`, a light
  pipeline-owned controller like `DigController`. It holds the config, the `env_seed` copy,
  and the `previous` / `current` snapshots. It advances the clock, emits events, and
  emits weather particles. It holds no per-entity data and no hidden RNG state.
- `WorldSystem` owns the persistent facts:
  - `clock: WorldClock` holds `game_ms: u64`. The default is 08:00 on day 0
    (`28_800_000`). Its only writer is `environment_update`.
  - `level_sky_exposed: std.ArrayList(bool)` is appended at the `appendLevelBaseZ` choke
    point, which gains a `sky_exposed: bool` parameter, so it is always the same length
    as `level_base_z`. **Both lists are reserved before either is appended**
    (`ensureUnusedCapacity` on `level_base_z` and `level_sky_exposed`, then two
    `appendAssumeCapacity`), so an OOM on the second reserve leaves both lengths
    unchanged. `addUndergroundLevelStack` likewise pre-reserves
    `level_sky_exposed` for `underground_count` beside its existing `level_base_z`
    reserve (`:1679`) in the same reserve-before-commit block. `addLevel` passes
    `level == 0`, preserving today's "surface is index 0" semantics.
    `addUndergroundLevelStack` passes `false`. Slice 38's `addElevatedLevelStack` passes
    `true` (Slice 69 addition (a), folded into [Slice 38](slice-38.md)).
  - Accessor: `levelSkyExposed(level) bool`.
  - Slice 49 checksum classification: `clock` and `level_sky_exposed` are **hashed**
    (and saved by Slice 46). `EnvironmentController` snapshots are **excluded**, as
    derived from `(env_seed, game_ms)`.

**Clock and calendar (integer, no float drift).**

- `game_ms` advances by `EnvironmentConfig.game_ms_per_step: u32 = 1000`, an integer.
  The default makes one game day last 24 real minutes. The value is validated in
  `1..=60_000`. The clock never advances from `delta_seconds`, wall clock or frame
  count. Paused gameplay runs no steps, so the clock does not advance.
- `k_ms_per_day = 86_400_000`. `day_index = game_ms / k_ms_per_day` and
  `time_of_day_ms = game_ms % k_ms_per_day`.
- `CalendarConfig` is a fixed array with no allocation: `months: [k_max_calendar_months = 16]Month`
  plus `month_count: u8`, where `Month = { days: u16, season: Season }`. The default is
  VoidLight's 4 × 30 days: spring, summer, autumn, winter. `day_of_year`, `month`,
  `day_of_month` and `year` come from a linear walk over at most 16 months, so cost is
  O(1). Month display names belong to Slice 53B's UI. No strings live in sim data.
- `Season = enum(u2) { spring, summer, autumn, winter }`.
- `SeasonConfig` per season holds `sunrise_minute`, `sunset_minute` and
  `weather_weights_permille: [7]u16`. The defaults are VoidLight's values in integer form:
  - Sunrise/sunset: spring 360/1140, summer 300/1260, autumn 390/1080, winter 450/1020.
  - Weights (clear, cloudy, rain, storm, fog, snow, wind):
    - spring {350,250,250,50,50,0,50}
    - summer {500,200,150,100,0,0,50}
    - autumn {300,300,200,50,100,0,50}
    - winter {250,250,100,50,50,250,50}
  - Validation: every row sums to exactly 1000, `sunrise - 60 >= 0`,
    `sunset + 60 <= 1440`, and `sunset - sunrise >= 120`.
- `DayPhase = enum(u2) { dawn, day, dusk, night }` is derived from the season's
  sunrise/sunset. This fixes VoidLight's split where phase bounds were fixed hours but
  daylight used per-season sunrise/sunset.
  - dawn = `[sunrise-60, sunrise+60)`
  - day = `[sunrise+60, sunset-60)`
  - dusk = `[sunset-60, sunset+60)`
  - night otherwise
- `daylight: f32` in `[0,1]` is 0 at night and 1 in day. It ramps through the dawn and
  dusk windows with `math.smoothstep`, a new core primitive with tests. Midnight is
  always night, so the sunrise/sunset jump at a season boundary never pops.

**Weather state machine (pure function of time, no stored state).**

- `WeatherKind = enum(u8) { clear, cloudy, rain, storm, fog, snow, wind }`. VoidLight's
  string-named `Custom` is not ported.
- `roll_index = game_ms / weather_roll_interval_ms`, with the interval defaulting to
  4 game hours (`14_400_000`), as in VoidLight. `weatherForRoll(k)` takes the season at
  the roll's start day and picks a kind by cumulative integer weights against
  `rng.boundedU32(env_seed, hi32(k), lo32(k), k_salt_weather_roll, 1000)`. No float
  accumulation is involved.
- The transition blends from `weatherForRoll(k-1)` to `weatherForRoll(k)` over
  `weather_transition_ms = 1_200_000` (20 game minutes, validated to be less than the
  interval):
  - `weather_blend = clamp((game_ms - k*interval) / transition, 0, 1)`
  - The snapshot carries `weather_from`, `weather_to` and `weather_blend`.
  - Because weather is a pure function of `(env_seed, game_ms)`, any time skip lands on the
    same weather as stepping there.
- `WeatherParams` (presentation) per kind holds `precipitation`, `wind_speed`, `light`,
  `haze_amount` and `saturation`. Values are blended linearly from→to. Defaults, ported
  from VoidLight's intensity and wind values:

  | Kind | precipitation | wind_speed | light | haze_amount | saturation |
  | --- | --- | --- | --- | --- | --- |
  | clear | 0 | 0.1 | 1 | 0 | 1 |
  | cloudy | 0 | 0.3 | 0.92 | 0.05 | 0.92 |
  | rain | 0.7 | 0.5 | 0.82 | 0.10 | 0.85 |
  | storm | 1.0 | 0.9 | 0.65 | 0.15 | 0.75 |
  | fog | 0 | 0.1 | 0.9 | 0.35 | 0.8 |
  | snow | 0.7 | 0.4 | 0.95 | 0.12 | 0.9 |
  | wind | 0 | 1.0 | 1 | 0 | 1 |

- Wind is presentation only: it drives particles, not sim.
  - Per roll, the direction is `rng.unitVec2(env_seed, hi, lo, k_salt_wind_dir)`,
    lerped from→to.
  - Speed is `wind_speed * k_max_wind_px_per_s` (96).
  - A gust multiplier `1 + 0.35*sin(2π·(game_ms % 420_000)/420_000)` is applied. The
    phase comes from integer time, so there is no accumulation.
- Lightning is also a pure function. `env_tick = game_ms / game_ms_per_step`.
  `strike(t)` is true when `storm_weight(t) * k_lightning_chance_per_step (1/480)`
  exceeds `uniformF32(env_seed, hi(t), lo(t), k_salt_lightning)`. `storm_weight` is the
  storm share of the blend at tick `t`. `flash` is
  `max over k in [0,12) of (strike(now-k) ? 1 - k/12 : 0)`, which costs 12 `mix64` calls
  per step. No `steps_since_lightning` state is stored.
- Salts are `k_environment_salt_base = 0x454E_0000` plus offsets. Offsets 1..4 are roll,
  wind direction, lightning and emit rounding. `+0x100 + 2i (+1)` covers spawn x/y for
  emit slot `i < 16`, and `+0x200 + i` covers drag jitter. Salts are local to
  `environment.zig`; the `.environment` domain isolates them from other streams.
  Weather-particle placement (spawn x/y, emit-rounding dither, drag jitter) is
  presentation-only and is one of Slice 49's named exemptions: it draws from the
  fixed literal `k_weather_particle_seed`, not `env_seed`, so it is deterministic but
  not varied by the session seed. Roll, wind direction, and lightning use `env_seed`.

**Environment modifiers (sim-affecting; VoidLight `EnvironmentModifiers` port).**

- `EnvironmentModifiers = { vision_scale: f32 = 1, hearing_scale: f32 = 1, move_speed_scale: f32 = 1 }`.
- The day/night component lerps between the day row {1,1,1} and the night row
  {0.55, 1.0, 0.9} by `daylight`.
- The weather rows (vision, hearing, move) are blended from→to:

  | Kind | vision | hearing | move |
  | --- | --- | --- | --- |
  | clear | 1 | 1 | 1 |
  | cloudy | 0.95 | 1 | 1 |
  | rain | 0.8 | 0.8 | 0.9 |
  | storm | 0.55 | 0.6 | 0.75 |
  | fog | 0.45 | 1 | 0.95 |
  | snow | 0.7 | 0.9 | 0.7 |
  | wind | 0.9 | 0.7 | 0.95 |

  Hearing is new relative to VoidLight: rain and wind mask sound.
- The combined value is the product, clamped to **`[0.25, 1.0]`**. The upper clamp of
  1.0 is load-bearing. Effective ranges never exceed the validated
  `max_ai_perception_*_range`, so the spatial scan radius, the candidate-check cap and
  `los_max_cells` stay valid. It also makes night and weather a perf win, because the
  scan radius shrinks.
- `EnvironmentModifierLookup = { sky: EnvironmentModifiers = .{}, level_sky_exposed: []const bool = &.{} }`
  with `forLevel(level)`. A level that is out of range or not exposed gets identity.
  Underground (cave) behavior is unchanged. The default `.{}` is an exact no-op, so
  tests, benches and existing callers keep their current behavior bit for bit.
- Default start is 08:00, clear, day → every scale is exactly 1.0. Existing pipeline
  tests run a few steps and stay at parity.
- Consumers:
  - **Perception**: `PerceptionConfig.environment: EnvironmentModifierLookup = .{}`. At
    gather time, `vision_range *= forLevel(level).vision_scale` and
    `hearing_range *= forLevel(level).hearing_scale` (the row already carries `level`).
  - **Movement**: `MovementSystem.applyIntents(bodies, frame, environment)` scales
    speed by `forLevel(worldLevelConst(entity) orelse 0).move_speed_scale`. This is AI
    only, matching VoidLight, which never slowed the player.
  - **Affect** keeps the base `vision_range` for its proximity ratio
    (`affect.zig:545-587`). Night changes whether a threat is *detected*, not how close
    a detected threat feels.
  - VoidLight's "caution" scale (night or storm raises fear) is **not** half-wired as a
    global fear multiplier. It belongs to Slice 42's "appraisal gains become data" (Slice
    69 addition (b), folded into [Slice 42](slice-42.md)).
- Sim-affecting outputs use only integer math and IEEE basic ops (`+ − × ÷`, min/max,
  the smoothstep polynomial). That covers modifiers, phase, weather kind/blend, and
  events, so they stay bit-reproducible under Slice 49's determinism contract. Trig
  (gust, wind direction, particle spawn) appears only in presentation outputs.

**Pipeline placement.**

- New `PipelineResource.environment` covers the per-step snapshot plus the clock it is
  derived from.
- New `StageId.environment_update` at **`stage_order` index 0**, before `dig_world_edit`:
  - `stageContract`: `.reads = .empty`, `.writes = { environment, world_events }`. It
    uses no `carried`: its only input is its own clock state.
  - `perception_update` adds `environment` to its reads.
  - `apply_ai_movement_intents` adds `environment` to its reads.
  - `runStage` arm: `try self.stageEnvironmentUpdate(step)`.
  - The comptime check proves ordering. A causal-effect test also pins it (see
    Acceptance checks).
- `EnvironmentController.step(world, frame)` does the following, serially on the main
  thread in O(1):
  1. `previous = current`.
  2. `world.clock.game_ms +|= game_ms_per_step`.
  3. `current = deriveSnapshot(...)`.
  4. Emit at most one event per kind per step by diffing `previous` and `current`.
  5. Return `EnvironmentStepStats`.
- `EnvironmentController.init(config, env_seed, initial_game_ms)` where
  `env_seed = seed.derive(.environment)` (append `SeedDomain.environment = 6`),
  computed once in `SimulationPipeline.init`, never per step. It derives
  `previous = current` without emitting. The pipeline passes
  `config.navigation_world.?.clock.game_ms`, or `WorldClock` default when there is no
  world. `resync(world)` is public for Slice 46's load path.
- Config: `SimulationPipelineConfig.environment: EnvironmentConfig = .{}`, validated at
  pipeline init with `error.InvalidEnvironmentConfig`.

**Events (typed, scalar, bounded).**

- New payload `environment_transition: EnvironmentTransitionEvent`, a tagged union:
  - `day_started: struct { day_index: u32 }`
  - `day_phase_changed: struct { previous: DayPhase, current: DayPhase }`
  - `season_changed: struct { previous: Season, current: Season }`
  - `weather_changed: struct { previous: WeatherKind, current: WeatherKind }`. Emitted
    only when the new roll picks a different kind.
  - `lightning_strike: void`
- Events use stage `.domain_reaction`. The step's at most 5 events are collected into a
  fixed local `[k_environment_max_events_per_step]SimulationEvent` array, then published
  as **one range with a single `finishWrite`**: `ensureCanAppend(n)` →
  `appendRangeCounts(1)` → `addCount(n)` → `prefixAppendedRanges` → one `rangeWriter`
  writing `n` records → `finishWrite()` once. This is the `appendRequired` sequence
  (`simulation.zig:341-351`) widened to `n` records, landed as a small
  `SimulationEvents.appendRequiredBatch([]const SimulationEvent) !void` helper. Calling
  `appendRequired` per record would rebuild stats over all ranges up to five times.
  Required semantics are unchanged: an exhausted budget fails the whole batch, never a
  silent drop. They reuse the `world_events` tag; no new event tag. `EventStats` gains
  the counter and the perf metric `simulation_events_environment_transition`.
- `EventProducerId.environment_update` has the fixed budget
  `k_environment_max_events_per_step = 5` (one per kind). A time jump that crosses
  several days still emits one `day_started` carrying the new value.
  `deriveDemoPopulationCapacity`'s `event_reserve` adds this constant.
  `SimulationPipeline.reserve` picks it up through the exhaustive switch.

**Weather particles (existing particle system, extended, not forked).**

- `ParticleRow` and `ParticleSpawn` gain `drag: f32 = 0`, validated to
  `[0, k_max_particle_drag = 20]` so `drag*dt <= 1/3`. `ParticleUpdateConfig` gains
  `air_velocity: math.Vec2 = .{}`.
- The kernel becomes `v += (a + drag*(air - v))*dt; p += v*dt`, using the same
  SIMD/scalar split. Terminal velocity falls out physically: `v_t = air + a/drag`.
- With `drag = 0` the result is **bit-identical** to today for every acceleration
  except `a = -0.0`. `0*(air-v)` is ±0 and `a + ±0 == a` for any nonzero `a` and for
  `a = +0.0`; for `a = -0.0`, `-0 + +0 = +0`, so `v += a*dt` sees `+0*dt` instead of
  `-0*dt`. `v + ±0` is `v` for any nonzero `v`, so the only observable difference is the
  sign of an exactly-zero velocity or position (`-0.0` vs `+0.0`), which compare equal
  and which no consumer distinguishes. This is documented, not hidden: the golden test
  includes `a = ±0.0` rows and asserts bit identity on every row except `a = -0.0`, and
  value identity (`==`) on the `a = -0.0` row.
  The debris pool is unchanged.
- Not ported from VoidLight: per-frame `vel *= 0.98` (not dt-scaled), trig keyed by row
  index (indices change on swap-remove), and `fast_rand`. Heterogeneity comes from
  ±20% drag jitter drawn at spawn.
- Second state-owned pool `GameDemoState.weather_particles`, capacity
  **`k_weather_particle_capacity = 2048`**. That is a fixed constant, independent of
  world and view size. Weather can never starve debris or gameplay effects.
- Emitter table per kind:
  - rain: a=(0,900), drag 3 (v_t ≈ 300 px/s), life 0.9 s, size 2–3, color
    (0.45,0.6,0.95,0.7→0.5), max 10/step.
  - storm: as rain, size 3, max 16/step.
  - snow: a=(0,120), drag 2 (v_t ≈ 60), life 6 s, size 3–5, white 0.9→0, max 3/step.
  - wind: a=0, drag 1 (v_t = wind), life 3 s, size 2, tan (0.75,0.68,0.5,0.5), max
    2/step.
  - clear, cloudy and fog emit nothing. Fog is haze.
  - Worst live count: storm 864, snow 1080. Both are under the 2048 cap.
- `EnvironmentController.emitWeatherParticles(pool, spawn_rect, base_z, exposed) EmitStats`
  runs after `pipeline.update`, before `weather_particles.update`, in
  `GameDemoState.update`:
  - Count per kind is `floor(precip_kind * blend_share * max_emit + u)`, where `u` is a
    dither seeded from `k_weather_particle_seed`. Both `from` and `to` emit
    proportionally, so a rain→snow change crossfades.
  - Spawn positions are uniform draws (`k_weather_particle_seed`) over
    `spawn_rect` = `GameDemoState.simViewRect()` (Slice 49; equal to `camera_rig.anchorRect()` once
    Slice 60 lands) expanded by 96 px. The rect is deterministic and not the render
    camera. This removes any sim-side dependency on Slice 60.
  - Depth is new `WorldDepth.weather = 3` on `base_z = levelBaseZ(player_level)`.
  - Nothing is emitted when `!levelSkyExposed(player_level)`.
  - Full-pool drops are counted, not grown.
- The weather pool is updated with `.air_velocity = current.wind`.
- `GameDemoState.syncInterpolatedState` (`game_demo_state.zig:615-619`) gains
  `self.weather_particles.syncPreviousPositions()` beside the debris pool, so
  pause/resume never lerps stale previous weather positions.

**Render side (depends on Slice 60).**

- `GameplayScene` gains `weather_particles: *const ParticleSystem` and
  `weather_visible: bool` (= `levelSkyExposed(player_level)`), so no rain draws
  underground.
- Weather records are camera-AABB-culled, then **spliced into `sort_indices` as one
  constant-depth run after the comparison sort**: binary search for the depth boundary,
  one tail move, then the existing linear span rebuild. They never pass through
  `std.mem.sort`. The splice gives the weather depth its own span, so
  `collectDenseInterleaveDepths` sees it as an interleave depth. `submitLayeredWorld` is
  unchanged.
- Capacities use the pool's fixed `capacity`, not `activeCount`, so a storm onset never
  grows a buffer mid-frame:
  - `spriteCommandCapacity` adds `weather_particles.capacity`.
  - `dynamicRecordCapacity` adds `weather_particles.capacity`.
- `environment_grade.sceneGradeFor(snapshot, sky_exposed) SceneGrade` is pure.
  `GameDemoState.render` lerps the grades of `previous` and `current` by
  `interpolation_alpha` and calls `renderer.setSceneGrade`.
  - Day/night keyframes are VoidLight `TimePeriodVisuals` converted to multiply colors
    `m = (1-a) + a·rgb`:
    - night rgb (0.078,0.078,0.235) a 0.353
    - dawn (1.0,0.549,0.314) a 0.118
    - day (1.0,1.0,0.784) a 0.031
    - dusk (1.0,0.314,0.157) a 0.157
  - Keyframes are walked continuously through the dawn window (night→dawn→day) and the
    dusk window (day→dusk→night) by window position. This replaces VoidLight's
    real-time exponential smoothing.
  - `multiply *= weather.light`, `haze = (0.72,0.75,0.80, haze_amount)`,
    `saturation = weather.saturation`, `flash = 0.6·flash`.
  - Not sky-exposed → `SceneGrade.neutral`, keeping today's cave look.
- Lightning (`lightning_strike`, sky-exposed) feeds `camera_rig.addTrauma(0.25)`
  (Slice 60). The thunder one-shot is in the audio item below.

**Diagnostics.**

- Comptime-gated perf metrics (compiled out in ReleaseFast):
  - `environment_day_phase`
  - `environment_weather_kind`
  - `weather_particles_emitted` / `_dropped` / `_active`
  - timings `pipeline_environment` and `gameplay_weather_particles`
- `game` scope `debug` log on `weather_changed` and `season_changed`, gated by
  `logging.enabled(.debug)`. These are rare edges, not per-step.
- `pipeline init` fails loudly on invalid config. There is no silent fallback.

**Out of scope (named, not dropped):**

- temperature (no consumer)
- scripted weather override (Slice 69D, gated) and sleep/time-skip API (Slice 69C)
- regional or biome weather (Slice 58's `chunkBiome`; Slice 69B)
- HUD clock and calendar text (Slice 53B)
- caution → affect (Slice 42)
- player speed scaling (product decision)

### Checklist

- [ ] `src/core/math.zig`: `smoothstep(edge0, edge1, x)` with tests (edges, clamping,
      monotonicity).
- [ ] `src/game/environment.zig`: `WorldClock`, calendar, season, phase, weather and
      modifier types and default tables with values as above. `EnvironmentConfig.validate`.
      Pure `deriveSnapshot`, `weatherForRoll`, `strike` and flash. Salts.
- [ ] `src/game/simulation_seed.zig`: append `SeedDomain.environment = 6` (Slice 49
      reserved value) and extend Slice 49's pinned-values test.
- [ ] `WorldSystem`: `clock` field. `level_sky_exposed` appended at `appendLevelBaseZ`
      with a new `sky_exposed` parameter, both lists reserved before either appends
      (`addLevel` → `level == 0`, `addUndergroundLevelStack` → false, its pre-reserve
      covers both lists). `levelSkyExposed()`. Tests: length sync, and an OOM on the
      `level_sky_exposed` reserve (`FailingAllocator`) leaves both lengths unchanged.
- [ ] Slice 49 checksum classification (and the matching Slice 46 save section):
      `WorldSystem.clock` and `level_sky_exposed` hashed + saved;
      `EnvironmentController` snapshots excluded (derived from `(env_seed, game_ms)`).
- [ ] `src/game/simulation.zig`: `EnvironmentTransitionEvent` payload,
      `EventProducerId.environment_update` with budget 5, `EventStats` counter and perf
      metric, and `SimulationEvents.appendRequiredBatch` (one range, one
      `finishWrite`). `deriveDemoPopulationCapacity.event_reserve` += 5.
- [ ] `src/game/environment_controller.zig`: `init` / `resync` / `step` /
      `emitWeatherParticles` / `modifierLookup` / snapshot accessors.
- [ ] `simulation_pipeline.zig`: `PipelineResource.environment`,
      `StageId.environment_update` at index 0, `stageContract` arms (new stage plus
      `environment` reads on `perception_update` and `apply_ai_movement_intents`),
      `runStage` arm, config field, stats and perf. Raise `@setEvalBranchQuota` at
      `simulation_pipeline.zig:287` if the comptime contract walk needs it.
- [ ] `systems/perception.zig`: `PerceptionConfig.environment`. Gather-time vision and
      hearing scaling. The pipeline passes the lookup.
- [ ] `systems/movement.zig`: `applyIntents` environment parameter (AI move scale by
      level exposure). Update callers and benches.
- [ ] `systems/particle.zig`: `drag` column plus `ParticleSpawn.drag`, `air_velocity`
      config, SIMD and scalar kernel, drag validation.
- [ ] `render_depth.zig`: `WorldDepth.weather = 3`, extend the ordering test.
- [ ] `game_demo_state.zig`: `weather_particles` pool (2048), emission over
      `simViewRect()` and update in `update`, `syncInterpolatedState` resync of the
      weather pool, `render` grade wiring, lightning → trauma (needs 60).
- [ ] `render_prep.zig`: `GameplayScene` weather fields, constant-depth weather run
      splice, fixed-capacity reservations (update test and bench scene literals).
- [ ] `src/game/environment_grade.zig`: `sceneGradeFor` keyframe and weather mapping,
      grade lerp (needs Slice 60's `SceneGrade`).
- [ ] Weather audio:
      - Add `AudioAssetId`s for the rain loop, wind loop and thunder one-shot, and the
        files under `assets/audio/sfx/`, in the same change.
      - `AudioController.queueEnvironmentAudio(audio, frame)` reacts to
        `environment_transition` with edge-latched loops `LoopingSfxId` 2 (rain/storm)
        and 3 (wind), plus thunder on `lightning_strike`.
      - **Stays open until authored audio files exist.** No dead `AudioAssetId` tags.
- [ ] (added by Slice 67) Event-log feed arm for `environment_transition`
      per Slice 67B (`lightning_strike` → `null`).
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes. The
      season, day-phase, and weather names become `StringId`s. Otherwise 67E
      migrates them.
- [ ] Docs:
      - `docs/simulation-tiers-and-pipeline.md`: stage, resource, event payload,
        producer budget.
      - `docs/architecture.md`: environment ownership, clock as a persistent world fact,
        modifier contract, tint split with 60.
      - `docs/rendering-assets-shaders.md`: weather pool and the weather-run splice.

### Acceptance checks

- [ ] Pure tests:
      - calendar and phase boundaries for every season (including midnight and
        season-boundary continuity of `daylight`)
      - weather is deterministic for equal `(env_seed, game_ms)` and differs across session seeds
      - zero-weight kinds never roll, for example no summer snow over 10k rolls
      - blend math
      - time-skip invariance: N steps equal one jump, field by field
      - lightning and flash purity
      - modifiers are clamped to `[0.25,1]`, are identity underground, and are exactly
        1.0 at the default start
- [ ] Event tests:
      - at most one event per kind per step
      - a multi-day jump emits a single `day_started`
      - fixed emission order
      - an exhausted budget fails `appendRequiredBatch`, not a silent drop
      - a step with several transitions publishes them as one range (range count
        grows by exactly 1)
- [ ] Integration tests:
      - Perception: a hostile at 0.7× range is perceived by day and not at night on the
        surface, and is perceived at night underground.
      - Movement: the AI move scale applies only to sky-exposed levels.
      - Pipeline causal-effect test: "pipeline applies this step's environment
        modifiers before perception".
      - Perception serial == threaded with a non-identity lookup.
- [ ] Particle tests:
      - scalar == SIMD with drag
      - `drag = 0` is bit-identical to a golden produced by the pre-slice kernel formula,
        with `a = ±0.0` rows included (value-identical only on `a = -0.0`, as
        documented above)
      - pause/resume (`syncInterpolatedState`) leaves weather previous == current
      - velocity converges to `air + a/drag`
      - weather emission is deterministic per
        `(k_weather_particle_seed, game_ms, snapshot)` and bounded by per-step max and
        pool cap
      - drop counter
- [ ] `FailingAllocator` proofs (after init/reserve, exercising the real multi-worker
      `ThreadSystem`):
      - environment stage plus event append
      - weather emission plus weather pool update
      - render prep with a full weather pool
- [ ] Determinism: two pipeline runs of N steps from the same seed produce identical
      snapshots, event streams, and Slice 49 `simulationChecksum()` traces (`game_ms`
      and `level_sky_exposed` are hashed). A different session seed changes the
      weather roll sequence.
- [ ] Bench (one `BenchmarkGroup` per workload, hyphenated names, sizes in
      `defaultItemCounts`, registered in `src/benchmarks/runner.zig`):
      - New group `particles-weather` (`particles.zig` `weather_group`; default items
        2048, drag plus wind): `zig build bench -- --group particles-weather`. Report
        against `--group particles`; no unexpected multi-x cost.
      - New group `render-game-prep-weather` (`render_game_prep.zig`
        `weather_group`, full weather pool): `zig build bench -- --group
        render-game-prep-weather`.
      - `zig build bench -- --group perception` shows no regression with identity
        lookup.
- [ ] Manual run (with Slice 60): a day/night cycle visibly tints across dawn and dusk.
      Rain and snow particles drift with wind and stop underground. Lightning flashes and
      shakes the camera.
- [ ] `zig build verify` passes.

### VoidLight reference

**Port (re-architected):**

- Calendar and season model: `include/managers/GameTimeManager.hpp:48-89`,
  `src/managers/GameTimeManager.cpp:18-104, 236-289`.
- Seasonal weather probabilities and the 4-game-hour roll: `GameTimeManager.hpp:35-43, 361`,
  `.cpp:329-355, 541-577`.
- Time-change event kinds as typed scalar `SimulationEvents`: `.cpp:291-327`.
- Environment modifier tables and clamp: `src/ai/EnvironmentModifiers.cpp:25-41`
  (tables) and `:47-68` (combine and clamp), `include/ai/EnvironmentModifiers.hpp:14-21`.
  Upper clamp tightened to 1.0.
- Day/night tint colors: `include/events/TimeEvent.hpp:254-275`.
- Composite tint formula: `res/shaders/composite.frag.glsl:21-23`.
- Weather params: `src/events/WeatherEvent.cpp:94-143`.
- Rain terminal-velocity idea: `src/managers/ParticleManager.cpp:2568-2578`.
- Rain and snow emitter tuning: `ParticleManager.cpp:1814-1907`.

**Do not port:**

- `float m_totalGameSeconds` plus `std::chrono::steady_clock`: float drift and wall
  clock in gameplay (`GameTimeManager.hpp:331-343`, `.cpp:110-114, 178-234`).
- `static thread_local std::mt19937 gen{std::random_device{}()}` (`.cpp:547`).
- `shared_ptr` events with `std::string` payloads (`.cpp:295-325`).
- Singleton managers and string-named `changeWeather`/`Custom` weather
  (`WeatherController.cpp:211-215`, `WeatherEvent.hpp:28-48`).
- Real-time exponential tint smoothing pushed into a renderer singleton
  (`DayNightController.cpp:134-157`).
- Fixed-hour `TimePeriod` bounds inconsistent with per-season sunrise/sunset
  (`TimeEvent.hpp:29-40` vs `GameTimeManager.cpp:391-399`).
- Per-frame, non-dt drag (`ParticleManager.cpp:2690-2692`).
- Frame-accumulated `m_windPhase` (`:838`).
- Row-index-keyed trig turbulence (`:2512-2515, 2551-2553`).
- `fast_rand` (`:2635`).
- Screen-space spawn coordinates hardwired to a 1920 width (`:1419-1435`).
- Temperature curve (`GameTimeManager.cpp:506-525`, no consumer).
- `-ffast-math` (`CMakeLists.txt:56,64`).

