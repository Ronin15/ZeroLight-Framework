## Slice 69B: Regional (Biome) Weather

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 59](slice-59.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **58** (`chunk_biomes`, `chunkBiome`,
`BiomeId.none = 0xFF`, `worldgen/spec.zig`) and **59** (`environment.zig`,
`EnvironmentController`, `EnvironmentModifierLookup`, events, weather pool,
grade, audio). The render-side items (grade, weather draw) also depend on
**60**, the same way Slice 59's do. Slice 42's caution addition and this slice
both read the modifier lookup; whichever lands second migrates the other's call
site (checklist below). Lands after 58 and 59.

Goal: weather becomes a property of place. A world with authored weather
regions rolls independent, phase-staggered weather per region. Perception
range, AI move speed and caution read the modifiers of the region under the
entity. The player sees, hears and feels the weather of the region they stand
in, and region borders cross-fade. Weather stays a pure function of
`(EnvironmentConfig, env_seed, game_ms, chunk_biomes)`, so nothing new is
persisted. A single-region world (every `initDemo*` world, and any spec without
`weather_regions`) is identical to Slice 59.

### Current foundation

- **Slice 59 (planned contract).**
  - Model and constants:
    - `WeatherKind` (7 kinds);
    - `weatherForRoll(k)` with `rng.boundedU32(env_seed, hi32(k), lo32(k),
      k_salt_weather_roll, 1000)` against the start-day season's
      `weather_weights_permille`;
    - `weather_roll_interval_ms = 14_400_000` and
      `weather_transition_ms = 1_200_000`;
    - lightning `strike(t)` with a 12-tick flash, and per-roll wind direction;
    - salts at `k_environment_salt_base = 0x454E_0000` + 1..4 (roll, wind,
      lightning, emit rounding), `+0x100 + 2i (+1)` (spawn x/y) and
      `+0x200 + i` (drag jitter).
  - `EnvironmentModifiers {vision, hearing, move}` is a day/night × weather
    product clamped to `[0.25, 1]`. `EnvironmentModifierLookup {sky,
    level_sky_exposed}` exposes `forLevel`. Perception (gather time) and
    `MovementSystem.applyIntents` (AI only) consume it.
  - `environment_transition` events with
    `k_environment_max_events_per_step = 5`, published through
    `appendRequiredBatch`.
  - Presentation:
    - `emitWeatherParticles(pool, spawn_rect, base_z, exposed)` over
      `simViewRect()` + 96 px, with draws from `k_weather_particle_seed` (a
      Slice 49 exemption);
    - the pool is updated with `.air_velocity = current.wind`;
    - `environment_grade.sceneGradeFor(snapshot, sky_exposed)`;
    - `AudioController.queueEnvironmentAudio` with rain/wind loops and
      thunder;
    - lightning → `camera_rig.addTrauma(0.25)`.
- **Slice 58 (planned)**: `WorldSystem.chunk_biomes: []u8` holds the
  spec-order biome index at each surface chunk's center, with `.none` on
  non-generated worlds. `max_worldgen_biomes = 32`. Biomes are listed in order,
  and the strict loader rejects unknown keys.
- **Live chunk math**: `WorldSystem.chunkCoordForWorldPos`
  (`src/game/world_system.zig:1567-1572`) composes `math.worldPosToCell`
  (`src/core/math.zig:47`) with `chunkCoordForCell` (`:1557-1562`).
- `PerceptionGatherRow` already carries `pos_x`, `pos_y` and `level` per
  observer (`src/game/systems/perception.zig:274-299`).
- Slice 46: `content_fingerprint` folds content catalogs whose data affects the
  simulation but is not saved.

### Architecture notes

**Region model.**

- `k_max_weather_regions = 8` is a fixed cap; the region index is a `u8`
  below `region_count`.
- Region 0 is the default region. It uses Slice 59's `SeasonConfig` weights,
  salts and phase unchanged, so any world with `region_count == 1` is
  bit-identical to Slice 59.
- The calendar, season, day phase, daylight and the day/night modifier row are
  global.

**Content.** `assets/world/worldgen.json` (Slice 58 spec, still `version: 1`; `"..."` marks abbreviated fields)
gains:

```json
"weather_regions": [
  { "id": "highland",
    "spring": [200,250,250,150,100,0,50], "summer": [350,250,150,150,50,0,50],
    "autumn": [200,300,200,100,150,0,50], "winter": [100,200,50,50,100,450,50] } ],
"biomes": [ { "id": "forest", "weather_region": "highland", "...": "..." } ]
```

- Weight rows use Slice 59's order (clear, cloudy, rain, storm, fog, snow,
  wind).
- At most `k_max_weather_regions - 1 = 7` authored regions; ids are unique.
- Every row sums to exactly 1000.
- A biome without `weather_region` maps to region 0. An unknown name fails with
  `UnknownWeatherRegion`.
- `worldgen/spec.zig` resolves these into `RegionalWeatherConfig`.
- `GameDemoState.initProceduralWithRuntimeAssets` copies the result into
  `SimulationPipelineConfig.environment.regional`. `initDemo*` keeps the
  default (`region_count = 1`).

**Config (`environment.zig`).**

```zig
pub const k_max_weather_regions: u8 = 8;
pub const RegionalWeatherConfig = struct {
    region_count: u8 = 1,
    // Row 0 is never read: region 0 uses `EnvironmentConfig.seasons`.
    region_weights: [k_max_weather_regions][4][7]u16 = @splat(@splat(@splat(0))),
    // Indexed by Slice 58 biome id; value < region_count.
    biome_region: [max_worldgen_biomes]u8 = @splat(0),
};
```

`EnvironmentConfig.validate` gains these checks, each failing with
`InvalidEnvironmentConfig`:

- `region_count` is in `1..=8`;
- each row of regions `1..region_count` sums to 1000;
- every `biome_region` entry is below `region_count`.

**Per-region time base (phase stagger).**

- `t_r = game_ms + offset_r`, where
  `offset_r = r * (weather_roll_interval_ms / k_max_weather_regions)`. That is
  30 game minutes per region at the default interval, so region borders do not
  all flip at once.
- Roll index `k_r = t_r / interval`.
- The roll's season is the season of the day containing
  `k_r * interval - offset_r` (saturating at 0).
- Blend is `clamp((t_r - k_r*interval) / transition, 0, 1)`, as in Slice 59.
- `offset_0 = 0`, so region 0 is exactly Slice 59.

**Per-region draws.** Region 0 uses Slice 59's salts. For region `r >= 1`:

- roll: `k_environment_salt_base + 0x300 + r`;
- wind direction: `k_environment_salt_base + 0x310 + r`;
- lightning: `k_environment_salt_base + 0x320 + r`.

Each region uses its own `region_weights[r][season]`. Lightning `strike_r(t)`
uses region r's storm share at tick `t`, and flash is the 12-tick max per
region. Cost per step is at most 8 × (2 roll + 12 lightning + 2 wind)
`mix64` calls, which is O(1).

**Snapshot.**

- `EnvironmentSnapshot` gains
  `regions: [k_max_weather_regions]RegionWeather`, filled for indices below
  `region_count`.
- `RegionWeather = { from: WeatherKind, to: WeatherKind, blend: f32,
  storm_weight: f32, wind: math.Vec2, flash: f32, modifiers:
  EnvironmentModifiers }`.
- Slice 59's single-region fields (`weather_from`, `weather_to`,
  `weather_blend`, `wind`, `flash`) move into `regions[0]`. Every caller takes
  a region index: the grade, the emitter, audio, events and tests.
- `modifiers` for region r is the global day/night row times region r's
  blended weather row, clamped to `[0.25, 1]` (Slice 59 rule).

**Lookup (`EnvironmentModifierLookup`, value type, no allocation).**

```zig
pub const EnvironmentModifierLookup = struct {
    region_modifiers: [k_max_weather_regions]EnvironmentModifiers = @splat(.{}),
    level_sky_exposed: []const bool = &.{},
    chunk_biomes: []const u8 = &.{},          // borrowed from WorldSystem; immutable after load
    biome_region: [max_worldgen_biomes]u8 = @splat(0),
    grid: ChunkGrid = .{},                     // tile_size, width, height, chunk_size_tiles, chunks_x
    pub fn regionAt(self, level: u16, x: f32, y: f32) ?u8;      // null when level is not sky-exposed
    pub fn forPosition(self, level: u16, x: f32, y: f32) EnvironmentModifiers;
};
```

- **Region resolution.**
  - Compute `ci = chunkIndexForWorldPos(grid, x, y)`, a pure free function
    factored out of `WorldSystem.chunkCoordForWorldPos` (`:1567`) so the sim
    lookup and `WorldSystem` cannot drift.
  - Read `b = chunk_biomes[ci]`.
  - The region is 0 if `chunk_biomes` is empty or `b == 0xFF`; otherwise it is
    `biome_region[b]`.
  - Elevated sky-exposed levels (Slice 38) use the surface chunk of the same
    column.
- `forPosition` returns identity for a level that is out of range or not sky
  exposed; otherwise it returns `region_modifiers[region]`.
- It replaces Slice 59's `forLevel`. Every caller migrates in this slice:
  - perception gather, using `pos_x`/`pos_y`/`level`;
  - `MovementSystem.applyIntents`, using the resolved body position;
  - Slice 42's caution gather, if 42 has landed.
  `forLevel` is deleted, so no dead API remains.
- The default `.{}` is an exact identity everywhere, so tests and benches keep
  their behavior.
- `EnvironmentController.modifierLookup(world)` fills the lookup from the
  current snapshot plus `world.chunk_biomes`. Workers read it as an immutable
  value.

**Events (scalar, bounded).**

- `weather_changed` becomes `{ region: u8, previous: WeatherKind, current:
  WeatherKind }`. There is at most one per region per step.
- `lightning_strike` becomes `{ region: u8 }`. There is at most one per region
  per step.
- `k_environment_max_events_per_step` becomes the comptime expression
  `global_kind_count + 2 * k_max_weather_regions`:
  - `global_kind_count` = `EnvironmentTransitionEvent` tags minus the two
    regional tags, which is 3 today;
  - so the budget is **19**, or 20 once Slice 69C's `time_skipped` tag exists;
  - a multi-day jump flips at most every region once, so the budget is a true
    worst case.
- `SimulationPipeline.eventCapacitySum()` picks the new budget up through the exhaustive
  `EventProducerId` switch (Slice 72 B1); the demo's `capacity_limit` literal test is
  re-pinned.

**Presentation.** The player's region drives every presentation reaction; none
of it feeds the simulation.

- **Player region.** `GameDemoState` calls
  `environment.regionAt(player_level, player_center)` once per fixed step.
  Not sky exposed means no weather presentation, as in Slice 59.
- **Cross-fade latch.**
  - `WeatherPresentation { region: u8 = 0, from_region: u8 = 0,
    crossfade_steps_left: u8 = 0 }` lives on `GameDemoState`. It is
    presentation-only, and Slice 49 classifies it as excluded.
  - A region change starts a cross-fade of
    `k_region_crossfade_steps = 60` fixed steps (1 s). It is linear in the
    steps left. It blends the grade, the pool air velocity and the
    emitter's per-kind shares between `from_region` and `region`.
  - It resets on `syncInterpolatedState` and on Slice 69C's `time_skipped`.
- **Emission by position-sampled region.**
  - Per kind `K`, compute `share_max(K)` = the max over regions of region r's
    precipitation-weighted blend share of `K`.
  - Draw `n = floor(share_max(K) * max_emit(K) + u)` candidate positions
    exactly as Slice 59 does. Each candidate is kept iff
    `uniformF32(k_weather_particle_seed, i, emit_tick, k_environment_salt_base
    + 0x400 + i) < share_{regionAt(p)}(K) / share_max(K)`.
  - This acceptance draw is skipped when `region_count == 1`, so
    single-region emission stays bit-identical to Slice 59.
  - The work is bounded by the per-kind `max_emit` (at most 16 per step).
  - Positions outside any sky-exposed column are dropped. Rain therefore stops
    at a border instead of following the player's region.
- **Pool air velocity.** It is the player region's `wind`, cross-faded.
  **Decided:** a pool-wide air velocity, so particles near a border drift with
  the player-region wind. A per-row air column would add 8 B per particle and
  a region lookup per particle per step for a presentation detail that the
  60-step cross-fade already softens. There is no per-row air column.
- **Grade.**
  `sceneGradeFor(snapshot.regions[player_region], sky_exposed)`,
  cross-faded.
- **Lightning.** Camera trauma (0.25) and thunder fire only for
  `lightning_strike.region == player_region` when the player is sky exposed.
- **Audio.** The rain, storm and wind loops become level-triggered. Each step,
  `AudioController` derives the desired loop set from the player region's
  blended weather and edge-latches start/stop on change. A border crossing
  therefore switches loops without needing a `weather_changed` event for that
  region.

**Pipeline.** No new `StageId` and no new `PipelineResource`.
`perception_update` and `apply_ai_movement_intents` already read `environment`
(Slice 59), and the per-region values are part of that resource.

**Persistence and checksum.**

- No new `WorldSystem`, `DataSystem` or controller state needs persisting.
  Snapshots are derived from the clock, as in Slice 59.
- `chunk_biomes` is already hashed and saved (Slice 58).
- `WeatherPresentation` is presentation state and excluded from the checksum.
- **Content fingerprint (Slice 46).** The weather-region tables affect sim
  modifiers but are not saved. `WorldGenSpec.weatherRegionFingerprint()`
  computes a `std.hash.Crc32` over `region_count`, `region_weights` and
  `biome_region`, and it folds into `content_fingerprint`. A mismatched load
  fails with `SaveContentMismatch`.

**Fixed budgets.**

| Constant | Value | Reasoning |
| --- | --- | --- |
| `k_max_weather_regions` | 8 | O(1) per-step cost (≤ 128 `mix64`); fits `u8`; region tables stay inline. |
| region phase offset | `interval / 8` | Staggers flips. Region 0 has offset 0, which preserves parity. |
| `k_environment_max_events_per_step` | `3 + 2*8 = 19` (+1 with 69C) | One `weather_changed` and one `lightning_strike` per region per step. |
| `k_region_crossfade_steps` | 60 | 1 s presentation fade at a border. |
| emission | Slice 59 per-kind `max_emit` | The acceptance draw never adds candidates. |

**Determinism.**

- Sim outputs (kinds, blends, modifiers, events) use integer math plus IEEE
  basic ops. Region resolution is IEEE divide/floor plus integer clamps, the
  same formula as `chunkCoordForWorldPos`.
- `forPosition` is row-local, so perception and movement stay serial ==
  threaded.
- Time-skip invariance holds per region.

**Diagnostics.**

- Comptime-gated perf metric: `environment_player_region`.
- `game`-scope `debug` on `weather_changed` now includes the region.
- `info` at pipeline init with `region_count`.
- No per-step logging.

### Checklist

- [ ] `environment.zig`:
      - `RegionalWeatherConfig` and its validation;
      - per-region time base, salts, rolls, wind, lightning and flash;
      - `RegionWeather` with Slice 59's fields moved into `regions[0]`;
      - per-region modifiers;
      - `EnvironmentModifierLookup.regionAt` / `forPosition`, with `forLevel`
        deleted;
      - `ChunkGrid`.
- [ ] `world_system.zig`: factor `chunkIndexForWorldPos` out of
      `chunkCoordForWorldPos`, which calls it. Add a parity test for both
      across edge, out-of-bounds and negative positions.
- [ ] `worldgen/spec.zig`: `weather_regions` + biome `weather_region` keys,
      validation (`UnknownWeatherRegion`, row sums, duplicate ids, region cap),
      and `weatherRegionFingerprint()`. Ship one authored region in
      `worldgen.json`: `highland`, mapped from `forest`.
- [ ] Migrate every `forLevel` caller to `forPosition`: perception gather,
      `MovementSystem.applyIntents`, and Slice 42's caution gather if 42 has
      landed.
- [ ] Events: `weather_changed.region`, `lightning_strike.region`, and the
      comptime budget expression. Update `EventStats` and the reserve tests to
      the new literal.
- [ ] `GameDemoState`:
      - `WeatherPresentation` latch and cross-fade;
      - per-region emission with the acceptance draw (skipped when
        `region_count == 1`);
      - player-region air velocity and grade;
      - lightning trauma filter.
      `AudioController`: level-triggered loop set and thunder region filter.
- [ ] Slice 46: fold `weatherRegionFingerprint()` into `content_fingerprint`,
      with a test that changing one weight changes the fingerprint.
- [ ] Slice 67B (earlier in the merged order): the `event_log_feed.lineFor` arm for
      `weather_changed` covers only the player's region (the
      `WeatherPresentation.region`); every other region returns `null`. Test:
      a flip in a non-player region adds no log line.
- [ ] Docs:
      - `docs/architecture.md`: the regional weather model and the
        presentation-follows-player rule;
      - `docs/simulation-tiers-and-pipeline.md`: region-keyed modifiers and
        the event budget.

### Acceptance checks

- [ ] Parity: with `region_count == 1`, snapshots, modifiers, event kinds,
      order and values (now with `region = 0`), and weather-particle emission
      are identical to the Slice 59 baseline over 2 game days of steps.
- [ ] Pure tests:
      - per-region weather is deterministic and differs between regions under
        the same `env_seed`;
      - zero-weight kinds never roll per region (10k rolls);
      - phase offsets make region flips land on different steps;
      - N steps equal one jump for every region;
      - lightning and flash purity per region.
- [ ] Lookup:
      - `forPosition` returns region r's modifiers inside an r-mapped chunk
        and identity underground;
      - an empty `chunk_biomes` resolves to region 0;
      - resolution matches `WorldSystem.chunkCoordForWorldPos` at chunk edges.
- [ ] Integration: two observers at night, one in a storm region and one in a
      clear region, perceive a hostile at 0.7× vision differently. Perception
      is serial == threaded with a multi-region lookup.
- [ ] Event budget: a multi-day jump that flips all 8 regions publishes one
      range within budget. An exhausted budget fails `appendRequiredBatch`.
- [ ] Presentation:
      - a border crossing cross-fades over exactly 60 steps;
      - emission across a border keeps no rain particle in the clear region;
      - thunder plays only for player-region strikes.
- [ ] `FailingAllocator`: the environment stage with 8 regions, regional
      emission, and render prep with a full weather pool allocate nothing after
      reserve.
- [ ] Bench:
      - `zig build bench -- --group perception` shows no regression with a
        multi-region lookup versus identity;
      - `--group particles-weather` is recorded with region sampling.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Port:** the idea of region-scoped weather (`WeatherEvent` region name and
  geographic bounds, `include/events/WeatherEvent.hpp:140-151`,
  `src/events/WeatherEvent.cpp:315-318,412-416`), re-keyed to authored biome
  regions.
- **Do not port:**
  - weather triggered by the *player's* position against float bounds
    (`isInBounds`, `WeatherEvent.cpp:471+`). In ZeroLight, weather belongs to
    the place, and the player only selects what is presented;
  - string region names at runtime;
  - the singleton `EventManager::changeWeather` dispatch.

