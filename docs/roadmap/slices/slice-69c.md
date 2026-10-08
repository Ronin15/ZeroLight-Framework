## Slice 69C: Time Skip

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 59](slice-59.md), [Slice 49](slice-49.md), [Slice 75](slice-75.md), [Slice 64B](slice-64b.md), [Slice 67B](slice-67b.md), [Slice 67E](slice-67e.md), [Slice 57B](slice-57b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: a time skip fast-forwards the observer's world to the next dusk or dawn,
advancing its whole simulation across the skipped interval at reduced
fidelity, not just the calendar; a game with a player may call it rest.
Calendar transition events fire through the normal snapshot diff, the result
is deterministic, and replays reproduce a skip from its input bit.

### Current foundation

- `src/app/input.zig` `Action` and default key bindings. `T` is unbound.
- `SimulationFrame.dig_intent` is captured in `main_thread_inputs`
  (`pipeline.captureDigIntent`), the precedent for a per-step player input.
- `ConstPerceptionSlice.nearest_threat` (`data_system/types.zig`) is written
  only for agents that thought this step, so an agent that saw the player
  and has not thought since keeps a stale entry.
- Step-domain consumers, not calendar time: AI memory staleness and affect
  decay (per processed step), and the planned schedules of 55, 56, 57, 61,
  and 62.
- Slice 59 (not landed): the clock is written only by `environment_update`;
  a multi-day jump emits one `day_started`; calendar validation guarantees
  every day contains every phase.

### Architecture notes

- `Action.rest` is a gameplay action with pinned replay bit 12 (Table T1);
  rising-edge latched, and a refused press is consumed
  (`.claude/rules/input-state.md`). The latch is hashed and saved (64B / 46)
  so a save taken with the key held never produces a spurious rest on load.
- The target is the next dawn or dusk phase start, always within two days
  (pure, validated calendar).
- Owner decision (2026-10-08): the skip fast-forwards the world's simulation
  at reduced fidelity (75's cadences); step-domain schedules, memory, affect,
  and cognition advance across the interval. How the interval is stepped is
  set by the design pass with a cost model
  (`.claude/rules/engine-design.md`); results never depend on render cadence
  or worker count (`.claude/rules/simulation.md` § Determinism,
  `.claude/rules/threading.md`). Other worlds are untouched.
- In a game with a player, a skip is refused only when a same-level NPC near
  the player (within the maximum perception range) currently targets it;
  stale far entries never block. The check reads committed state on the main
  thread, only on a press.
- Presentation snaps on a skip: weather pool cleared, grade snapped, regional
  cross-fade reset, audio loops re-evaluated.
- Player-facing text: action name, an event-log line per applied skip, and
  a toast on refusal, raised by the gameplay state, never by simulation.
- VoidLight: port the dusk/dawn targets; do not port float hour setters or
  wall-clock time-scale hotkeys.

### Checklist

- [ ] `Action.rest` with binding, classification, routing tests, and replay
      bit 12.
- [ ] Pure skip target and `time_skipped` event kind.
- [ ] Rest capture with edge latch, phase toggle, and threat gate; external
      request resource carried by the environment stage.
- [ ] Reduced-fidelity fast-forward of the world's simulation across the
      skipped interval, serial and threaded.
- [ ] Event payload, stats, and bound update.
- [ ] Gameplay state capture call and presentation snap on `time_skipped`.
- [ ] `rest_held_last` hashed and saved; checksum tag and save format bumped
      live + 1.
- [ ] Strings, event-log arm, and refusal toast (67E, 67B, 57B).
- [ ] Bench `time-skip`: skip cost at three populations, linear in
      population × interval ÷ cadence.
- [ ] Docs: `docs/state-stack-and-input.md` (rest action),
      `docs/simulation-tiers-and-pipeline.md` (skip semantics, interactions),
      `docs/architecture.md` (single clock writer; calendar vs step time).

### Acceptance checks

- [ ] Skip target is the first phase start after now, within two days, for
      every season and phase, around midnight, season boundaries, and a year
      wrap.
- [ ] A skip at step S leaves the clock at the target with the snapshot
      `deriveSnapshot` gives there.
- [ ] Day → dusk emits the phase change and `time_skipped` in one range; dusk
      → dawn across midnight emits one `day_started`.
- [ ] Threat gate: a near same-level targeting hostile refuses; a stale far
      one or one on another level does not; holding the key through a refusal
      does not rest later.
- [ ] Step-domain schedules, memory, affect, and cognition advance across
      the skip; agents have moved and acted; a second world is unchanged.
- [ ] A recorded session with a rest replays to the same checksum trace;
      serial == threaded across the rest step; save with the key held, load,
      keep holding: no `time_skipped` on either side.
- [ ] `FailingAllocator`: capture, skip step, and publish allocate nothing.
- [ ] `zig build verify` passes.
