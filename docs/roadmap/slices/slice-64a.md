## Slice 64A: Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 52D](slice-52d.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 49's harness, replay flag bit0, and
`simViewRect()`, and 52D's select-form `simd`/`math` min/max and lint
precedent. Rebases with 50 on `thread_system.zig` worker entry. No stage,
resource, or store change.

Goal: pausing and resuming never changes simulation-visible state, so a
paused-and-resumed run is bit-identical to an unpaused one with the same
input; every scalar float `min`/`max`/`clamp` in `src/game/` has one pinned
semantics on x86, arm64, runtime, and comptime; float bits used as keys are
canonical; a non-default MXCSR/FPCR is caught at the step boundary instead of
silently desynchronizing a world.

### Current foundation

- `GameDemoState.onPause`/`onResume` call `syncInterpolatedState`, which runs
  `SimulationPipeline.syncPreviousPositions` (→
  `MovementSystem.syncPreviousPositions`), `ParticleSystem.syncPreviousPositions`,
  and `syncCameraToPlayer`, overwriting `camera_current`, the source of
  `simViewRect()`.
- `movement_integrate` writes `previous = position` before integrating, so
  `previous_x/previous_y` are both the render interpolation start and the
  simulation's lagged pose. Stages before it read them and observe the
  resync: spatial index build, perception observers and the player
  candidate, AI `player_target`, and steering snapshots; dig facing reads the
  previous position.
- `Player.onPause`/`onResume`/`syncPreviousPosition` are called only by their
  own test.
- Render interpolates the camera and bodies/particles with
  `context.interpolation_alpha` through `render_prep.submitGameplayFrame`.
- After 52D, only `src/core` pins float min/max. `src/game/` has many non-test
  `@min`/`@max` sites (mostly integer, with float sites in collision,
  steering, perception data, the demo state, arbitration, and the audio
  controller) and nine `std.math.clamp` calls; `math.clamp` is an `f32`
  branch form that is already deterministic.
- Float bits feed the path-key hash directly (`pathfinding/types.zig`,
  `@bitCast(key.goal.x/.y)`).
- The only `std.math` transcendental in `src/` is `math.atan2`; its caller is
  render-only.
- Nothing reads the FP environment. A Zig 0.17 probe confirmed `stmxcsr` reads
  `0x1f80` by default with sticky status bits set by normal arithmetic, `mrs
  fpcr` lowers on `apple_m1`, and runtime x86 `0/0` (`0xffc00000`) differs
  from a folded `0/0` (`0x7fc00000`) in the same binary.

### Architecture notes

- Pause (decision): presentation alpha hold. Nothing but the simulation writes
  the previous pose (integrate, snaps, spawns); while paused and until the
  first executed step after resume, render draws the settled pose (alpha 1),
  through a presentation-only flag no pipeline or checksum reads. Pause never
  touches the sim-view camera. The resync APIs are removed. Replay flag bit0
  keeps its wire position, renamed `pause_boundary_before_step` (Table T1),
  and producers still set it.
- Float min/max/clamp (decision): `core/math.zig` provides generic `min`/`max`
  equal to `@min`/`@max` for integers (same value and result type) and select
  form for floats, delegating `Float4` to 52D's `simd` helpers so scalar and
  SIMD select forms have one owner; `clamp` becomes generic with branch
  semantics and an inverted-range debug assert that a NaN bound does not trip.
  `src/game/` spells every min/max/clamp through `math`. Float results change
  only on ±0 ties and NaN operands; integers are unchanged.
- Idiom lint enforces the `math` spellings in `src/game/` and routes
  `std.math` transcendentals in `src/` through `core/math.zig`, outside
  tests.
- Key bits: one `math.floatKeyBits` maps every NaN to one quiet NaN and −0 to
  +0, so equal-comparing floats give equal keys on every target; every
  float-to-bits conversion feeding a hash, map, sort, or dedup key goes
  through it. The checksum is separate (64B keeps ±0
  distinct).
- FP environment: `core/fp_env.zig` asserts the IEEE default control bits
  (status flags masked) under runtime safety only, at every pipeline step
  entry (each world instance's step), at worker start, at lane-thread start
  (51, or addition (k)), and at headless-session init (64C); ReleaseFast pays
  nothing. A trip is fixed at the dependency boundary that changed the
  environment.
- No allocation added; every helper is pure or reads one register.

### Checklist

- [ ] Alpha hold in `GameDemoState` (pause, resume, update, render); resync
      APIs and their tests removed; replay flag constant and docs renamed.
      Tests with 49's harness: pause and resume leave the 120-step checksum
      trace unchanged (replaces 49's resync test); the hold lasts until the next
      executed step; pause does not move the sim view; 49's replay test still
      matches with the pause flag set.
- [ ] `math.min`/`max`, generic `clamp`, parameter renames, and migration of
      every non-test `src/game/` `@min`/`@max` and `std.math.clamp`. Tests on
      runtime inputs: integer value and type parity; float ±0 and NaN bits,
      `Float4` lanes equal to `simd` min/max, comptime equal to runtime;
      `clamp` branch semantics and NaN-bound behavior.
- [ ] Idiom-lint coverage for raw min/max/clamp in `src/game/` and
      transcendentals outside `core/math.zig`.
- [ ] `math.floatKeyBits` and the path-key migration; tests for NaN payloads,
      −0, a normal value, and equal path keys for goals at −0 and +0.
- [ ] `core/fp_env.zig` with pure x86 and arm64 control classifiers, a
      host-read test, and the step, worker, and lane call sites (lane only if
      51 has landed); no test writes MXCSR/FPCR.
- [ ] Docs: Determinism Contract (pause invisibility, pause-boundary flag,
      float min/max/clamp, key bits, FP environment); `docs/architecture.md`
      Coordination Boundaries (pause freezes presentation only).
- [ ] Rule additions when this lands: float min/max/clamp and transcendental
      routing (`.claude/rules/memory-performance.md`); float key bits, pause
      invisibility, and FP environment (`.claude/rules/simulation.md`).

### Acceptance checks

- [ ] `zig build verify` passes; `idiom-lint` reports no hits for the new
      coverage, and each check fires on a temporary, uncommitted edit.
- [ ] The pause trace test passes and no `syncPreviousPosition` remains in
      `src/`.
- [ ] `zig build test` passes in Debug, ReleaseSafe (assertion live, no trip),
      and ReleaseFast.
- [ ] Manual (display): pausing with movers in motion shows a frozen frame,
      resume shows no backward hitch, and the F2 overlay draws in place.
- [ ] Collision, steering, perception, spatial-index, and AI groups show no
      regression beyond run-to-run spread on adjacent commits in ReleaseFast,
      unless the hot function's disassembly is identical or a strict subset;
      numbers in the landing commit.
