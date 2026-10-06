## Slice 19: Steering And Local Avoidance

Goal: turn pathfinding results into smoother NPC movement by adding local
steering, avoidance, and stuck/replan policy above the pathfinder without moving
that transient behavior into `DataSystem`.

Current foundation:

- Slice 14 AI processing provides deterministic AI decision output; Slice 19
  routes that output through navigation intents before final steering movement.
- Slice 18 pathfinding can provide frame-delayed path waypoints and unavailable
  results.
- Slice 13 collision contacts and spatial-query foundations provide the data
  shape needed for local crowd and obstacle decisions.
- `SteeringSystem` consumes high-level navigation intents, pathfinding status,
  dense steering components, movement slices, and static obstacle data, then
  emits final NPC movement intents through deterministic threaded range writes
  after main-thread path/status preparation.

Architecture notes:

- Steering should be a system or state-owned feature controller that consumes
  path results and typed SoA views, then emits movement intents or rule outputs.
- Persistent tuning data such as agent radius, desired speed, or avoidance class
  may live in dense `DataSystem` components. Per-step neighbor lists, waypoint
  cursors, avoidance scratch, and replan queues should stay transient or
  state-owned.
- Avoidance and steering benchmarks should measure the processor cost directly
  rather than masking it behind the pathfinding benchmark.

Checklist:

- [x] Add path-following state needed to turn completed paths into movement
      intents.
- [x] Add local obstacle and agent avoidance using bounded fixed scratch.
- [x] Add stuck detection, replan cooldowns, and unavailable-path backoff.
- [x] Define arbitration between player input, AI steering, collision response,
      and future rule outputs.
- [x] Add deterministic tests for waypoint following, avoidance ordering, replan
      backoff, and no steady-state hot-loop allocation.
- [x] Add steering/local-avoidance benchmarks that report agent count, bounded
      avoidance checks, accepted samples, intents emitted, and threaded/adaptive
      detail where used.

Acceptance checks:

- [x] NPCs can follow path waypoints without sharp frame-to-frame oscillation.
- [x] Nearby NPCs and static obstacles are avoided through bounded local work.
- [x] Unavailable or stale paths do not cause per-frame re-request loops.
- [x] Steering outputs compose through typed movement intents or rule outputs
      with deterministic order.
- [x] `zig build fmt`, `zig build test`, `zig build check`, `zig build verify`,
      and `zig build bench -- --profile quick --group steering --details` pass.

Slice 19 lands steering as a separate gameplay processor. AI now emits
`NavigationIntent` goals, `SteeringSystem` owns runtime steering rows,
path-request cooldown/backoff, local avoidance scratch, deterministic priority
arbitration, and threaded final movement-intent emission. Only the steering
stage writes final NPC `MovementIntent`s. Player movement remains direct input,
and collision response still resolves after movement.

**Hardening follow-up (post-Slice 27, no new slice number):** chasing a moving
goal (the player) produced a visible NPC direction wiggle — a discrete flip in
the chosen base direction (path-following vs. direct-fallback toggling while a
goal-cell requantization is in flight, a fresh corridor replacing a stale
waypoint, or a wander-epoch change) snapped the heading in one step instead of
turning smoothly. `RuntimeRow` gained `prev_dir_x/y`/`has_prev_dir`, and
`smoothBaseDirection` (steering.zig) blends the previous emitted direction
toward the new target by `steering_turn_smoothing = 0.15` per fixed step
(~10 steps to mostly converge at 60Hz) before it reaches
`SelectedWorkRow.base_dir`. The first direction observed for a runtime row is
used as-is (no startup lag). Benchmarked before/after on `zig build bench --
group steering` at 128/512/1024 agents: no measurable regression (differences
within normal run-to-run noise).


