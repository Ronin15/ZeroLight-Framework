## Slice 69D: Scripted Weather Override

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md) (gated on the first scripted weather consumer) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated.** Gate: the first game-side scripted consumer
lands. That is a quest, cutscene or world-event controller that must force a
weather state for a time window, such as "a storm starts when the quest
begins". That consumer's slice lands this checklist in the same change, so no
request API ships without a producer. Depends on **59**, and on **69B** when
regions exist (the override is per region; without 69B there is one region).

Goal: a deterministic, persistent, per-region weather override window that
blends in and out over Slice 59's transition time. The weather stays a pure
function of `(config, env_seed, game_ms, overrides)`.

### Architecture notes

**Persistent state.**

- `WorldSystem.weather_overrides: [k_max_weather_regions]WeatherOverride` is a
  fixed inline array indexed by region.
- `WeatherOverride = struct { active: bool = false, kind: WeatherKind = .clear,
  start_ms: u64 = 0, end_ms: u64 = 0 }`.
- Slice 49 classifies it as hashed; Slice 46 saves it as one fixed section
  (validated `kind`, `end_ms > start_ms` when active).

**Request.**

- `WeatherOverrideRequest = union(enum) { set: struct { region: u8, kind:
  WeatherKind, duration_ms: u32 }, clear: struct { region: u8 } }` is
  scalar-only.
- Producers call `frame.tryAppendWeatherOverride(request) bool` into
  `StepState.weather_override_requests`, a fixed
  `[k_max_weather_override_requests_per_step = 8]` queue cleared in
  `beginStep`. A full queue refuses the request and counts it as
  `weather_override_requests_refused`.

**Apply (commit seam).**

- `EnvironmentController.applyOverrideRequests(world, frame)` runs from
  `applyStructuralCommandsAndPostCommitEvents` after the structural commit, in
  append order. This is the Slice 61 `AffectImpulse` seam precedent: nothing is
  pending at a step boundary.
- `set` writes `{active = true, kind, start_ms = clock.game_ms, end_ms =
  start_ms + duration_ms}`.
- `clear` writes `active = false`.
- Validation: `region < region_count`, and `1 <= duration_ms <=
  k_max_weather_override_ms = 7 * k_ms_per_day`. An invalid request is counted
  and dropped. The next step's `environment_update` derives from the new value.

**Pure blend.** `deriveSnapshot` covers region r at time t (in region r's time
base from 69B) in four cases:

1. Not active, or `t < start_ms`: the natural roll.
2. `start_ms <= t < end_ms`: `from` is the natural `to` at `start_ms`, `to` is
   `kind`, and `blend = clamp((t - start_ms) / weather_transition_ms, 0, 1)`.
3. `end_ms <= t < end_ms + weather_transition_ms`: `from = kind`, `to` is the
   natural `to` at `t`, and blend ramps the same way.
4. Afterwards: the natural roll.

An expired override needs no sweep, because the function handles expiry. A
`weather_changed` event fires through the existing diff.

**Pipeline contract.** `PipelineResource.weather_overrides` is written at the
commit seam, so it is external to the stage graph. Add it to
`external_resources`, and `environment_update` carries it.

**Fixed budgets.**

- `k_max_weather_override_requests_per_step = 8` (one per region);
- `k_max_weather_override_ms = 7 days`;
- one override slot per region.

### Checklist

- [ ] `WeatherOverride` store on `WorldSystem`. Slice 49 classification
      (hashed) and Slice 46 save section with validation.
- [ ] `WeatherOverrideRequest`, the fixed per-step queue, and
      `tryAppendWeatherOverride` with its refusal counter.
- [ ] `applyOverrideRequests` at the commit seam, with validation and counters.
- [ ] The `deriveSnapshot` override blend, in pure form.
- [ ] `PipelineResource.weather_overrides` (external, carried by
      `environment_update`).
- [ ] The gating consumer's producer call, in the consumer's own slice.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md` (override seam, purity).

### Acceptance checks

- [ ] Pure tests: blend in, hold, blend out, and natural-after. An override
      replaced mid-window; `clear` mid-blend. N steps equal one jump while an
      override is active.
- [ ] A request appended at step N takes effect in step N+1's snapshot.
      Nothing is pending across the boundary.
- [ ] Save/load round-trip (Slice 46) with an active override reproduces the
      checksum trace. An invalid saved override is rejected.
- [ ] `FailingAllocator`: queue append, apply and derive allocate nothing.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Port:** forced weather with a transition time
  (`EventManager::changeWeather(name, transition, mode)`,
  `src/managers/EventManager.cpp:326-343`; the demo cycle at
  `src/gameStates/EventDemoState.cpp:715-735`).
- **Do not port:**
  - string weather names and the `Custom` type;
  - the no-op `WeatherEvent::forceWeatherChange`
    (`src/events/WeatherEvent.cpp:377-383`);
  - immediate dispatch from the caller's thread.

