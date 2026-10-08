## Slice 69C: Time Skip (Rest)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md), [Slice 49](slice-49.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **59** (`WorldSystem.clock`,
`EnvironmentController`, `environment_update` at `stage_order` index 0, and
pure `deriveSnapshot`) and **49** (the pinned replay bit table; `SeedDomain` is
unchanged). It also builds on slices that land earlier in the merged order:
**67A** (scancode bindings, `actionForScancode`), **64B** (hashed input
latches and the `"pipeline_history"` save section), **67E** (`StringId`),
**67B** (event-log feed), and **57B** (HUD toast). The first consumer ships in
this slice: the gameplay action `Action.rest`. Lands after 59. If it lands
before 69B, Slice 59's literal event budget 5 becomes 6; after 69B, the
comptime formula picks up the new tag.

Goal: the player can rest until the next dusk or dawn. The skip writes only the
calendar clock, and it does so inside the clock's only writer
(`environment_update`), so every transition event fires through the normal
snapshot diff. Every other system's behavior across a skip is decided and
deterministic. Replays reproduce a skip from the recorded input bit.

### Current foundation

- **Slice 59 (planned).**
  - `WorldClock.game_ms: u64` is written only by `environment_update`.
  - `EnvironmentController.step` does `previous = current`, advances by
    `game_ms_per_step`, derives the snapshot, and emits events by diff. A
    multi-day jump emits a single `day_started`.
  - `resync(world)` is the load path.
  - Validated calendar: `sunrise - 60 >= 0`, `sunset + 60 <= 1440`,
    `sunset - sunrise >= 120`. Phase windows: dawn
    `[sunrise-60, sunrise+60)`, day `[sunrise+60, sunset-60)`, dusk
    `[sunset-60, sunset+60)`, night otherwise.
  - Time-skip invariance holds by construction.
- **Input.**
  - `src/app/input.zig` defines `Action` (`:9-26`) and default key bindings
    (`:35-53`), keyed by `SDL_Keycode` today with `actionForKey` (`:202`).
    Slice 67A (earlier in the merged order) converts every default to
    `SDL_SCANCODE_*` and the lookup to `actionForScancode`; a slice landing
    after 67A declares its default as a scancode.
  - Slices 56 (`J`), 57 (`H`) and 60 (`=`/`-`) take more keys. `T` is free.
  - Slice 49 pins `held_gameplay_bits` 0–11 (Table T1: 8 `attack`,
    9 `use_item`, 10/11 zoom); appending a bit needs no version bump.
  - Slice 44 lists later-slice actions as Controls rows automatically.
  - Slice 64B classifies `interact_held_last`, the `DigController` latches,
    56's `attack_held_last`, and the 57 use-item latch as
    `checksum_hashed_fields`, saved in Slice 46's `"pipeline_history"`
    section.
- **Per-step input precedents.**
  - `SimulationFrame.dig_intent` is captured in `main_thread_inputs` by
    `pipeline.captureDigIntent` (`src/game/game_demo_state.zig:518`).
  - `external_resources` already includes `action_intents`
    (`src/game/simulation_pipeline.zig:161`); `action_react` carries it
    (`:225-229`).
- `ConstPerceptionSlice.nearest_threat: []const EntityId`
  (`src/game/data_system/types.zig:497`), with `entities` beside it
  (`data_system/perception.zig:128-147`). It is written only for observers in
  that step's think set (`systems/perception.zig:1572-1574`), so an observer
  that saw the player, then left the cognition halo or went dormant, keeps
  `nearest_threat == player` indefinitely. The player's level is
  `Player.current_level` (`player.zig:20`); an observer's is
  `DataSystem.worldLevelConst` (`data_system/system.zig:742`).
- **Step-domain consumers.** These are not calendar time:
  - Slice 61 `regrow_at_step`;
  - Slice 56 `next_attack_step`;
  - Slice 57 `despawn_step`;
  - Slice 62 `next_eligible_step` and the step-derived cursors;
  - AI memory staleness, which is +1 per processed step
    (`systems/ai_memory.zig:233-276`);
  - affect decay (`systems/affect.zig:483-493`);
  - Slice 55 coast cadences.

### Architecture notes

**Input and capture.**

- `Action.rest` has default `SDL_SCANCODE_T` (Slice 67A lands first), no
  gamepad default, and is classified by `isGameplayAction`; the lookup is
  `actionForScancode`. It takes pinned replay **bit 12** (Table T1), the next
  free bit after Slice 60's 11, appended to Slice 49's reserved list in this
  change.
- `EnvironmentController.captureRest(input, frame, data, player)` is called
  through `pipeline.captureTimeSkip(...)` in `main_thread_inputs`, beside
  `captureDigIntent`.
  - It keeps a rising-edge latch `rest_held_last: bool`, set to the raw held
    state on every capture. A refused press is consumed: the player releases
    and presses again. The only write on acceptance
    (`frame.time_skip = ...`) is infallible, so no swallowed-error path can
    leave the latch out of step with a queued request.
  - On a rising edge it picks the target phase from the current snapshot:
    `.dawn` or `.day` → `.dusk`, and `.dusk` or `.night` → `.dawn`.
  - **Threat gate.** Once per rising edge it scans the committed
    `ConstPerceptionSlice` (`entities`, `nearest_threat`). The rest is
    refused only when some observer meets all three conditions:
    1. `nearest_threat == player.entity` (index and generation);
    2. the observer's `worldLevelConst` (missing → 0) equals
       `player.current_level`;
    3. the observer's movement body `previous_position` lies within
       `rest_threat_radius_px = 512` of the player's `previous_position`,
       compared squared (`dx² + dy² <= 512²`). `previous_position` is the
       stage-3 pose that last step's perception judged, so the gate measures
       the same geometry that produced `nearest_threat`. An observer without a
       movement body never blocks.
    - Why the extra conditions: `nearest_threat` is only refreshed for
      think-set observers, so a hostile that saw the player and then left the
      cognition halo or went dormant keeps a stale `nearest_threat == player`.
      Without the level and radius checks, one such entry anywhere in the
      world would refuse rest for the rest of the session.
    - `rest_threat_radius_px` is a fixed constant equal to the perception
      validator cap `max_ai_perception_vision_range = 512`
      (`data_system/types.zig:478`): no observer can see the player from
      farther away, so a fresh threat is never excluded. Comptime-assert
      `rest_threat_radius_px >= max_ai_perception_vision_range`. It never
      derives from world size.
    - A refusal counts `rest_refused_threat` and writes no request. The scan
      is O(perception rows) with one slot resolve per matching row, on the
      main thread, only on a press, and reads only committed state.
  - Otherwise it sets `frame.time_skip = .{ .until_phase = target }`.
- `TimeSkipRequest = struct { until_phase: DayPhase }` holds scalars only.
  `SimulationFrame.time_skip: ?TimeSkipRequest = null` is cleared in
  `beginStep`. No duration-based kind ships, because it would have no producer.

**Pure target (`environment.zig`).**

- `timeSkipTargetMs(config, now_ms, phase) u64` checks candidate days
  `d ∈ {day(now), day(now)+1, day(now)+2}` in order. Each candidate is
  `d·k_ms_per_day + window_start_minute(season(d), phase)·60_000`, where the
  window starts are dawn = sunrise−60, day = sunrise+60, dusk = sunset−60, and
  night = sunset+60. It returns the first candidate greater than `now_ms`.
- Validation guarantees every day contains every phase, so the result always
  lies within 2 days.
- `comptime`/Debug assert: `target - now <= k_max_time_skip_ms = 2 *
  k_ms_per_day`. The worst real gap is 24 h plus a 240-minute seasonal sunset
  shift.

**Application (`EnvironmentController.step`, inside `environment_update`).**

1. `previous = current`.
2. If `frame.time_skip` is set, `world.clock.game_ms =
   timeSkipTargetMs(...)`. A skip step replaces that step's advance, so
   `game_ms_per_step` is not added and the clock lands exactly on the phase
   start. Otherwise `game_ms +|= game_ms_per_step`, as before.
3. `current = deriveSnapshot(...)`.
4. Events are emitted by diff (Slice 59), plus the new
   `time_skipped { skipped_ms: u32 }`. The jump is at most 2 days =
   172,800,000 ms, which fits `u32`.

The skip still runs one fixed step, so `step_count` advances by exactly one.
This refines the backlog note "writes the clock and calls `resync`": applying
the skip in the stage keeps transition events (`day_phase_changed`, per-region
`weather_changed`, `season_changed`, a single `day_started`) flowing to their
consumers. `resync` stays the load path only.

**Pipeline contract.**

- New `PipelineResource.time_skip_request`, added to `external_resources`
  because it is captured in input, before `update`.
- `stageContract(.environment_update).carried = {time_skip_request}`. Reads
  stay `.empty`; writes stay `{environment, world_events}`.
- No new `StageId`.

**Events.**

- `EnvironmentTransitionEvent.time_skipped: struct { skipped_ms: u32 }`.
  It is a global kind with at most one per step.
- The budget becomes 6 if 69B has not landed, else
  `4 + 2 * k_max_weather_regions = 20`.
- `EventStats` gains a counter and the perf metric
  `simulation_events_time_skipped`.

**Interactions (decided; all deterministic).**

| System | Behavior across a rest |
| --- | --- |
| Slice 59 day phase, season, daylight, weather, lightning, modifiers | Land on the pure value at the target (time-skip invariance). Modifiers apply from the next stage on. |
| Slice 62 time filter | `population_update` reads the new `day_phase` this step. Night-only anchors become eligible on their next cursor evaluation (≤ 32 steps). |
| Slice 61 regrowth, 56 cooldowns, 57 despawn, 62 intervals and cursors | Unchanged: step domain. Resting regrows nothing. Moving any of them onto `game_ms` would add a second absolute-schedule domain that can jump, so the framework keeps every absolute schedule on `step_count`. |
| AI memory staleness, affect decay, Slice 55 coasting | Unchanged: per processed step. |
| `step_count`, Slice 49 checksum header | +1, like any step. `game_ms` (already hashed) carries the jump. |
| Weather particles, grade, region cross-fade, audio loops | On `time_skipped`, `GameDemoState` calls `weather_particles.clear()`, snaps the grade (`previous = current` grade, no lerp) and resets `WeatherPresentation` (69B). `AudioController` re-evaluates loops from the snapshot. |

**Persistence, checksum and replay.**

- `game_ms` is already hashed and saved by Slice 59.
- `frame.time_skip` is a per-step input, cleared every step, so nothing is
  pending at a step boundary.
- `rest_held_last` is an input edge latch. It is classified
  `checksum_hashed_fields` (Slice 64B), like `interact_held_last` and the
  `DigController` latches. `EnvironmentController.hashSimulationState` folds
  only this latch; the snapshots stay excluded-derived. Slice 46's
  `"pipeline_history"` section saves it. Bump `checksum_format_tag` (live
  value + 1) and the save `format_version` (live value + 1; v7 in the merged
  order, Table T3) in this change.
  - Why hashed, not excluded: an excluded latch is `false` after a load. A
    save taken while T is held would then produce a spurious rising edge (a
    rest) only on the loaded side, breaking save/replay parity.
- Replay reproduces a rest from bit 12.

**Stats and diagnostics.**

- `EnvironmentStepStats.time_skips_applied` and capture counter
  `rest_refused_threat`, with comptime-gated perf metrics.
- A `game`-scope `debug` log on an applied skip, giving the target phase and
  `skipped_ms`.
- No per-step logging.

**Player-facing text (Slices 67E, 67B, 57B, 44; all land earlier).**

- `StringId.action_rest` plus its English `StringSpec` entry ("Rest"),
  required by 67E's exhaustive `actionNameId`.
- Slice 67B `event_log_feed.lineFor` arm for
  `environment_transition.time_skipped`: `event_rested_until` (1) "Rested
  until {0}", rendered through 67E's `strings.format` with the phase name
  (its own `StringId`, via `text`) as the text arg.
- `rest_refused_threat` is shown as a Slice 57B HUD toast ("Enemies are
  nearby"), raised by `GameDemoState` from the capture result, never from
  simulation code.
- Slice 44's Controls row for `rest` is automatic (list-form bindings; no
  settings version bump, Table T2). No pad default.

### Checklist

- [ ] `src/app/input.zig`: `Action.rest`, `SDL_SCANCODE_T` binding,
      `isGameplayAction`, and `actionForScancode` table tests.
      `input_router.zig` routing tests for all four policies. Pin replay bit
      12 in Slice 49's table (append "**12 `rest` (69C)**" to its reserved
      list), and keep the comptime pinned-set check passing.
- [ ] `environment.zig`: `TimeSkipRequest`, `timeSkipTargetMs`,
      `k_max_time_skip_ms`, and the `time_skipped` event tag.
- [ ] `EnvironmentController`: `captureRest` (edge latch, phase toggle, threat
      gate with the level and `rest_threat_radius_px` conditions and its
      comptime assert) and the skip branch in `step`.
      `SimulationFrame.time_skip` is cleared in `beginStep`.
- [ ] `simulation_pipeline.zig`: `PipelineResource.time_skip_request` in
      `external_resources`, `environment_update.carried`,
      `captureTimeSkip`, and stats/perf.
- [ ] `simulation.zig`: payload, `EventStats` counter, and budget update, with
      the reserve-test literal updated.
- [ ] `GameDemoState`: call `captureTimeSkip` in `main_thread_inputs`. On
      `time_skipped`: clear the weather pool, snap the grade, reset
      `WeatherPresentation` (if 69B has landed). `AudioController` re-evaluates
      loops.
- [ ] Slice 64B classification: `rest_held_last` is hashed
      (`EnvironmentController.hashSimulationState` folds it), and it joins
      Slice 46's `"pipeline_history"` section. `checksum_format_tag` and save
      `format_version` bumps (relative). Tests: toggling it changes the
      checksum, and saving with T held, loading, and continuing to hold T
      emits no `time_skipped`.
- [ ] Player-facing text: `StringId.action_rest` and `event_rested_until`
      with their English `StringSpec` entries; the 67B `lineFor` arm for
      `time_skipped`; the 57B toast for
      `rest_refused_threat`. Tests: the log line appears once per applied
      skip; a refused press raises one toast and no log line.
- [ ] Docs:
      - `docs/state-stack-and-input.md`: the rest action;
      - `docs/simulation-tiers-and-pipeline.md`: skip semantics and the
        interactions table;
      - `docs/architecture.md`: the clock stays single-writer, and calendar
        time differs from step time.

### Acceptance checks

- [ ] Pure tests for `timeSkipTargetMs`, for every season and phase. Cases:
      - just before and just after each window start;
      - midnight;
      - across a season boundary, so the next day has a different sunrise;
      - a year wrap.
      In every case the target is the first phase start after now and at most
      `k_max_time_skip_ms`.
- [ ] Applying a rest at step S gives the same snapshot (field by field) as
      `deriveSnapshot` at the target. `step_count` advances by exactly 1.
- [ ] Events:
      - rest from day to dusk emits `day_phase_changed(day→dusk)` and
        `time_skipped` in one range;
      - rest from dusk to dawn across midnight emits one `day_started`;
      - the event budget holds.
- [ ] Threat gate:
      - a same-level hostile within 512 px whose `nearest_threat` is the
        player refuses the rest; it is counted and the clock advances
        normally;
      - a hostile 600 px away holding a stale `nearest_threat == player`
        (it left the think set) does not block rest;
      - a hostile within 512 px on another level with
        `nearest_threat == player` does not block rest;
      - with no threat the rest applies;
      - holding T through a refusal does not rest when the threat clears;
        a new press does.
- [ ] Step-domain invariance: a depleted node with `regrow_at_step = S + 10`
      is still unavailable right after a rest at S, and available at S + 10.
      Memory staleness and affect values match a run without the rest.
- [ ] Slice 62 integration (if 62 has landed): a night-only anchor spawns
      within 32 steps after resting into night.
- [ ] Replay: a recorded session with a rest replays to the same per-step
      `simulationChecksum()` trace. Serial == threaded across the rest step.
- [ ] Save/load latch parity: save while T is held, load, keep holding T for
      60 steps: the per-step checksum trace equals the uninterrupted run's,
      and neither side emits `time_skipped`.
- [ ] `FailingAllocator`: the capture, the skip step and event publish
      allocate nothing after reserve.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Port:** setting the calendar directly
  (`include/managers/GameTimeManager.hpp:194,201`,
  `src/managers/GameTimeManager.cpp:357-390`), as one integer clock write.
- **Do not port:**
  - float `setGameHour` / `setGameDay` re-deriving `m_totalGameSeconds`;
  - the debug time-scale hotkeys (`src/gameStates/GamePlayState.cpp:131-135,
    836-847`), which give real-time-scaled `advanceTime`
    (`GameTimeManager.cpp:222`). ZeroLight never scales time by wall clock.

