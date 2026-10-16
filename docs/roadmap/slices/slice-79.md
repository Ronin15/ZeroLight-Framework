## Slice 79: Fixed-Step Input Edges, Frame-Time Snapping, And TimeLoop Cap Invariant

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Owner direction 2026-10-14: investigate the items
found in a game-loop read.

Goal: a gameplay press reaches the simulation however short it is and
however many frames pass between fixed steps.
Display timing jitter never turns a steady frame rate into an uneven run of
fixed steps per frame. `TimeLoop`'s catch-up cap is enforced in one place,
with its invariant held in code and tested, and no unreachable branch.

### Current foundation

- `src/main.zig` drains SDL events once per frame, then runs 0–5 fixed steps
  (`TimeLoop.shouldUpdate`).
- `InputState` (`src/app/input.zig`) holds level state only: `held_actions`
  set on key down/up, plus the raw stick. `FrameCommands.pressed_actions`
  holds press edges, but per frame and engine-only; it never reaches the
  simulation.
- Gameplay detects a press per step by comparing held state with its own
  last-step latch: `DigController.captureIntent`
  (`src/game/dig_controller.zig:155`) for `dig_hole`/`dig_down`/`dig_ramp`,
  and `SimulationPipeline.captureActionIntent`
  (`src/game/simulation_pipeline.zig:1159`) for `interact`.
- Failure scenario (derived from code, not reproduced): a press and its
  release that both arrive between two fixed steps leave `isHeld` false at
  every step, so no dig or interact intent is emitted. The window is the
  time between steps: up to ~16.7 ms at steady state, spanning several
  frames on a high-refresh display, and the whole stall during a hitch.
- `TimeLoop.beginFrame` (`src/app/time_loop.zig:22`) adds the raw measured
  frame interval (`SDL_GetTicksNS` deltas) to the accumulator. Nothing in
  `src/` queries the display's refresh rate; `frame_pacer.zig` knows only
  the fallback and background-cap intervals.
- Possible jitter (derived, not measured): with a 60 Hz display and the 60 Hz
  step, intervals measured slightly above and below 16.67 ms can run 0 steps
  in one frame and 2 in the next, so motion advances unevenly even though
  interpolation hides part of it. `runtime_perf_log` sums `fixed_updates` per
  report interval, so it cannot show the per-frame 0/1/2 distribution.
- `TimeLoop.beginFrame` clamps elapsed time to `max_updates_per_frame`
  steps; `finishUpdate` (`:43`) also trims the accumulator to
  `fixed_delta_ns - 1` after the fifth update. Derived: the accumulator
  enters every frame below one step (loop exit, that trim, or `reset`), so
  after the clamp five updates always leave it below one step and the trim
  never fires in the live loop. The test at `:97` reaches it only by writing
  the accumulator directly.

### Architecture notes

- `InputState` stays the simulation's only input; app commands stay in
  `FrameCommands`; fixed update never runs in render cadence
  (`.claude/rules/input-state.md`).
- What the simulation reads per step is per-step input, so a pending press
  is consumed at a step, never at a frame
  (`.claude/rules/simulation.md` § Determinism).
- Pause, modal block, and pad disconnect clear any new per-step input state
  on the same paths that call `releaseHeldGameplay`.
- Snapping changes only how many fixed steps run in a frame, never a step's
  length or contents (`.claude/rules/simulation.md` § Determinism), and
  never hides a real hitch: intervals outside the snap tolerance keep their
  measured value. The refresh interval follows the window's current display,
  including after a move between displays. Frame pacing policy stays in
  `frame_pacer.zig` (`.claude/rules/memory-performance.md`).
- `TimeLoop.max_updates_per_frame` stays a work budget (Slice 72 keeps it).

### Checklist

- [ ] Investigate input: a window-free test feeds a press and release
      between two fixed steps and shows whether a dig or interact intent is
      emitted; list every gameplay action captured on a press edge.
- [ ] Land how a sub-step press reaches the step's input capture, with
      tests: a tap between steps yields one intent; a held press yields one
      intent, not one per step; several steps in one frame consume a press
      once; pause and pad disconnect drop a pending press.
- [ ] Slice 49's pinned input script can express a sub-step tap.
- [ ] Measure jitter: record the per-frame fixed-step count distribution
      (0/1/2+) and measured interval spread in `runtime_perf_log`, then
      capture it on a 60 Hz display and on a high-refresh display with vsync
      on.
- [ ] If the measurement shows alternating step counts at a steady frame
      rate, snap measured intervals within a tolerance of a multiple of the
      display's refresh interval before they reach the accumulator, with
      tests: near-refresh intervals snap, a hitch keeps its measured value,
      and long-run simulated time tracks wall time. If it shows none, record
      the result here and close the item.
- [ ] `TimeLoop`: remove the unreachable trim or replace it with an
      assertion of the invariant; tests cover the clamp, the per-frame cap,
      and pause `reset` without forging accumulator state.

### Acceptance checks

- [ ] The sub-step tap, held-press, multi-step, and pause tests pass.
- [ ] The jitter measurement is recorded (display, refresh rate, step-count
      distribution) before and, if snapping lands, after.
- [ ] `TimeLoop` tests reach every branch through its public calls.
- [ ] `docs/state-stack-and-input.md` (Input Model) and
      `docs/architecture.md` (Frame Flow) describe the result.
- [ ] `zig build verify` passes.
