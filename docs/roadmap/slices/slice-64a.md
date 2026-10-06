## Slice 64A: Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 52D](slice-52d.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **49** (determinism harness, replay
`flags` bit0, `GameDemoState.simViewRect()`, `replayResync`) and **52D** (D3
select-form semantics for `simd.minFloat4`/`maxFloat4`/`math.clampMinMax`,
the `LIBM_BUILTIN` lint precedent). Edits `src/app/thread_system.zig`
`workerMain`; **50** changes `workerLoop` to take `*WorkerRecord`, so whichever
lands second rebases. No `StageId`, `stage_order`, `PipelineResource`, or
`DataSystem` change.

Goal: pausing and resuming never mutates simulation-visible state, so a
paused-and-resumed run is bit-identical to an unpaused run with the same
input; every scalar float `min`/`max`/`clamp` in `src/game/` has one pinned
semantics on x86, arm64, runtime, and comptime; float bits used as keys are
canonical; and a changed MXCSR/FPCR is caught at the step boundary instead of
silently desynchronizing.

### Current foundation (do not rebuild)

- **Pause resync mutates the pre-step pose (Slice 49 defect 2, live).**
  `GameDemoState.onPause`/`onResume` (`game_demo_state.zig:606-613`) call
  `syncInterpolatedState` (`:615-619`): `pipeline.syncPreviousPositions`
  (`simulation_pipeline.zig:930-933` → `MovementSystem.syncPreviousPositions`,
  `systems/movement.zig:53-55,125-133`), `particles.syncPreviousPositions`
  (`systems/particle.zig:436`), and `syncCameraToPlayer` (`:621-625`), which
  overwrites **`camera_current`** — the Slice 49 `simViewRect()` source.
- `movement_integrate` writes `previous = position` for every row before
  integrating (`systems/movement.zig:149-168`), so `previous_x/previous_y`
  are both the render interpolation start and the simulation's lagged pose.
  Stages that run **before** `movement_integrate` (`stage_order`,
  `simulation_pipeline.zig:262-282`) read them and therefore observe a resync:
  `spatial_index_build` (`systems/spatial_index.zig:602,857`), perception
  observer rows (`systems/perception.zig:954-955`) and the player candidate
  (`simulation_pipeline.zig:1092-1093`), AI `player_target` (`:1154`), and
  steering snapshots (`systems/steering.zig:476-479,583,643`). The walk gate
  (`systems/world_gate.zig:65,85`) runs after integrate and is not affected;
  dig facing (`dig_controller.zig:405`) reads `previous_position`.
- `Player.onPause`/`onResume`/`syncPreviousPosition` (`player.zig:90-101`)
  are called only by their own test (`:196-211`).
- Render: `GameDemoState.render` (`:566-590`) interpolates the camera
  (`interpolatedCamera`, `:632-637`) and passes `context.interpolation_alpha`
  into `render_prep.submitGameplayFrame`, which lerps bodies
  (`render_prep.zig:426-431`) and particles (`:486-487`).
- Float min/max today: 52D pins `simd.minFloat4`/`maxFloat4`/`clampFloat4`
  and `math.clampMinMax` to select form, **only in `src/core`**. `src/game/`
  has ~178 non-test `@min`/`@max` sites (audit script over `src/game/**`),
  mostly integer, with float sites such as `collision.zig:859-862,908-911,955`,
  `steering.zig:533,587,1388-1394`, `data_system/perception.zig:35`,
  `game_demo_state.zig:646-647,795-796,828-829,1040`, `arbitration.zig:188`,
  `audio_controller.zig:191`. `std.math.clamp` (which is `@max(lower,
  @min(val, upper))`) appears in `contact_query.zig:31`,
  `audio_controller.zig:180`, `settings_menu_state.zig:42`,
  `render_depth.zig:21`, `pathfinding/nav_grid.zig:194-195`,
  `pathfinding/types.zig:397,488`. `math.clamp` (`core/math.zig:27-31`) is a
  branch form (`f32` only; NaN `value` propagates; a ±0 `value` is returned
  unchanged) and is already deterministic.
- Float bits as keys: `pathfinding/types.zig:825` folds
  `@bitCast(key.goal.x/.y)` into the path-key hash.
- Transcendentals: the only `std.math` transcendental in `src/` is
  `core/math.zig:161` (`std.math.atan2`); its only caller is
  `ai_debug_overlay.zig:112` (render). `@sin` remains at
  `ai_debug_overlay.zig:358` until 52D.
- FP environment: nothing reads MXCSR/FPCR. Probe on Zig 0.17.0
  (`x86_64-linux`, Debug self-hosted and ReleaseFast LLVM): `stmxcsr` through
  `asm volatile ("stmxcsr %[dst]" : [dst] "=m" (value))` returns `0x1f80`;
  after a runtime `0/0` it reads `0x1f81` (the sticky IE flag), so status
  flags must be masked. `mrs %[ret], fpcr` with `[ret] "=r" (-> u64)` lowers
  to `mrs xN, FPCR` for `aarch64-macos -mcpu=apple_m1`. The same probe showed
  runtime x86 `0/0` = `0xffc00000` while LLVM-folded `0/0` = `0x7fc00000` in
  the same binary.
- Logging scopes: `core/logging.zig:16-24` (nine scopes: `app`, `assets`,
  `audio`, `core`, `game`, `render`, `platform`, `debug_overlay`, `perf`).
  This slice logs through `core` only.

### Architecture notes

**A1. Presentation alpha hold replaces the pause resync (decision).**

Rejected alternatives:
- *Separate render-history columns* (`render_previous_x/y` written by
  `movement_integrate`): adds two stores per row to the hottest SIMD kernel
  and two persistent columns to every movement body, only to give pause a
  column it may overwrite.
- *Simulation reads settled `position_x/y` instead of `previous_x/y`*:
  changes the cognition stack's one-step-lagged semantics (spatial index,
  perception, steering, AI targeting), re-tunes AI behavior, and is a much
  larger behavior change than the defect warrants.

Chosen: nothing writes `previous_x/previous_y` except the simulation
(`movement_integrate`, dig/teleport snaps, spawns). Pause freezes the
*presentation* instead:

- `GameDemoState.presentation_hold: bool = false` — a presentation field (not
  in any checksum, never read by the pipeline). Doc comment: "true from
  `onPause` until the first `update` after `onResume`; while true, `render`
  draws the settled pose (alpha 1)".
- `onPause`: `self.pipeline.pauseAudio(); self.presentation_hold = true;`
- `onResume`: `self.presentation_hold = true;` (the hold persists until a step
  executes, so frames rendered before the first post-resume step do not lerp
  back toward the one-step-old pose).
- `update`: first statement `self.presentation_hold = false;`.
- `render`: `const alpha = presentationAlpha(self.presentation_hold,
  context.interpolation_alpha);` where the private pure helper returns `1.0`
  when held, else the context alpha. `alpha` replaces
  `context.interpolation_alpha` in `interpolatedCamera` and
  `submitGameplayFrame` (bodies and particles).
- Visual equivalence: the old resync set `previous = position`, so any alpha
  drew `position`; alpha 1 draws `lerp(previous, position, 1)`, equal to
  `position` within 1 ulp (presentation only).
- **Removed** (no remaining callers once the resync is gone):
  `GameDemoState.syncInterpolatedState`, `SimulationPipeline.syncPreviousPositions`
  (+ its test at `simulation_pipeline.zig:1738-1744`),
  `MovementSystem.syncPreviousPositions` and the free
  `movement.syncPreviousPositions`/`syncPreviousPositionsImpl`,
  `ParticleSystem.syncPreviousPositions`, `Player.onPause`/`onResume`/
  `syncPreviousPosition` and their test (`player.zig:90-101,196-211`).
  `syncCameraToPlayer` stays for init (`:489`) only.
- **Camera**: pause no longer touches `camera_current` (sim-view source) or
  `camera_previous`; the held alpha draws `camera_current`. Slice 60's
  `CameraRig.syncPrevious()` is not called from pause/resume (see Checklist
  additions, Slice 60).
- **Replay flag**: Slice 49's `ReplayInputFrame.flags` bit0 keeps its wire
  position and is renamed in docs and code to `pause_boundary_before_step`
  (constant `replay_flag_pause_boundary: u8 = 1`). Producers still set it
  (Slice 51's `resync_pending`), and `verify` still calls
  `stepper.replayResync()` (now presentation-only), so a recording marks
  where pauses happened and stays faithful if a future change ever makes
  pause observable again (the new trace test below would catch that). No
  format version change.

**A2. Float min/max/clamp policy for `src/game/` (decision).**

The hazard: LLVM lowers float `@min`/`@max` to `minnum`/`maxnum`, whose
±0 result is unspecified; x86 runtime, x86 constant-bound, arm64 `fmaxnm`, and
comptime disagree on the sign of zero (52D audit), and NaN handling differs by
lowering. Compare/select forms are exact everywhere.

- `src/core/math.zig` gains, beside 52D's select-form `clampMinMax`:

  ```zig
  fn isFloatLike(comptime T: type) bool; // .float, .comptime_float, or @Vector of float
  /// `@min` for integers; select form for floats: ties (incl. −0 vs +0) and a NaN
  /// `a` yield `b`; a NaN `b` propagates. Same result at comptime and runtime on
  /// every target (52D D3).
  pub inline fn min(a: anytype, b: anytype) @TypeOf(@min(a, b)) {
      const T = @TypeOf(a, b);
      if (comptime isFloatLike(T)) {
          // Float4 has one owner of its select form: 52D's simd.minFloat4.
          if (comptime T == simd.Float4) return simd.minFloat4(a, b);
          return if (a < b) a else b;
      }
      return @min(a, b);
  }
  pub inline fn max(a: anytype, b: anytype) @TypeOf(@max(a, b)); // mirror: simd.maxFloat4 / `a > b`
  ```

  - The return type is literally `@TypeOf(@min(a, b))` and the integer body is
    literally `@min(a, b)`, so integer result-type narrowing is unchanged.
  - The vector arm delegates `simd.Float4` to 52D's `simd.minFloat4`/
    `maxFloat4`, so the scalar and SIMD select forms stay paired in one place
    (`src/core/simd.zig`). Any other float vector type (no current caller)
    fails with `@compileError("math.min/max: use the simd.zig helper for this
    vector type")` rather than growing a second select implementation.
    Probe on Zig 0.17.0: `const r: u8 = min(u32_runtime, 200)` compiles and
    equals `@min`, `@TypeOf(min(usize, u16))` equals `@TypeOf(@min(...))`, and
    `min(-0.0 runtime, 0.0)` returns `+0` (`0x00000000`).
  - Multi-argument `@min(a, b, c)` sites become nested `math.min` calls.
- `math.clamp` becomes generic and keeps its branch semantics:
  `pub inline fn clamp(value: anytype, lower: anytype, upper: anytype)
  @TypeOf(value, lower, upper)` = `if (value < lower) lower else if (value >
  upper) upper else value`. The parameters are renamed from `min`/`max`
  (Zig forbids a parameter shadowing the new `min`/`max` declarations;
  `clampMinMax` gets the same rename). Its first statement is
  `std.debug.assert(!(lower > upper));`, keeping the range check
  `std.math.clamp` performs (written as a negated `>` so a NaN bound does not
  trip it).
- Documented policy (`docs/coding-standards.md` "Simulation float rules"):
  - float min/max → `math.min`/`math.max`;
  - float clamp → `math.clamp` (NaN propagates) or `math.clampMinMax` (NaN →
    `lower`); SIMD → `simd.minFloat4`/`maxFloat4`/`clampFloat4`;
  - integer min/max also uses `math.min`/`math.max` in `src/game/` (uniform
    rule, so the lint needs no type inference).
- **Enforcement, `tools/lint_idioms.py`** — a new `GAME_ONLY_PATTERNS` list
  applied to `src/game/**` outside `test` blocks (reusing the existing
  `TEST_DECL` / `in_test` tracking, `lint_idioms.py:185,198-211`):
  - `RAW_MINMAX_GAME`: `@(?:min|max)\s*\(` — "use math.min/math.max: float
    @min/@max lower to minnum/maxnum, whose ±0/NaN results differ across
    x86/arm64/comptime; the math.zig wrappers are @min/@max for integers and
    select form for floats".
  - `STD_MATH_CLAMP_GAME`: `\bstd\.math\.clamp\s*\(` — "std.math.clamp is
    @max(lower, @min(v, upper)); use math.clamp".
  - Plus one `SRC_ONLY_PATTERNS` rule (`src/**` except `src/core/math.zig`,
    outside tests), `STD_MATH_TRANSCENDENTAL`:
    `\bstd\.math\.(?:atan2?|asin|acos|a(?:sin|cos|tan)h|sinh|cosh|tanh|exp2?|expm1|log(?:2|10|1p)?|pow|hypot|cbrt)\s*\(`
    (the `a(?:sin|cos|tan)h` alternative is needed because `asin\s*\(` cannot
    match `asinh(`)
    — "route transcendental math through src/core/math.zig so the
    cross-machine determinism contract has one owner (see 64D for atan2)".
    It flags nothing on today's tree (the only use is `math.zig:161`).
  - Precision: the `src/game/` rules are exact by construction (any raw
    builtin is flagged). Nothing in `src/core/simd.zig`/`math.zig` is in
    scope; those files own the primitives.
- Migration: every non-test `@min`/`@max` in `src/game/**` →
  `math.min`/`math.max` (add `const math = @import(".../core/math.zig");`
  where missing), and the eight `std.math.clamp` sites → `math.clamp`.
  Determinism impact (flagged): float results change only for ±0 ties and
  NaN-in-operand cases; integer results and types are unchanged.

**A3. Float bits feeding keys (decision).**

- `pub fn floatKeyBits(value: f32) u32` in `core/math.zig`: NaN →
  `0x7fc00000`, `-0.0` → `0x00000000`, otherwise `@bitCast(value)`.
  Equal-comparing floats (`-0 == +0`) must produce equal keys, and NaN
  payloads differ between x86 (`0xffc00000`) and arm64/LLVM folding
  (`0x7fc00000`).
- Migrate `pathfinding/types.zig:825` (`key.goal.x`/`.y`) to `floatKeyBits`.
- Rule (coding standards, review-enforced; a regex cannot see float
  operands of `@bitCast`): any float→bits conversion feeding a hash, map key,
  sort key, or dedup goes through `floatKeyBits`. The checksum is separate:
  64B canonicalizes NaN only and keeps ±0 distinct.

**A4. FP environment debug assertion (`src/core/fp_env.zig`, new).**

```zig
pub const supported: bool = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64;
/// x86_64 MXCSR control bits: DAZ(6), exception masks(7-12), RC(13-14), FZ(15).
/// Status flags 0-5 are sticky and set by normal arithmetic, so they are masked out.
pub const x86_control_mask: u32 = 0x0000_ffc0;
pub const x86_expected_control: u32 = 0x0000_1f80; // all masked, round-to-nearest-even, no FTZ/DAZ
/// aarch64 FPCR: FIZ(0) AH(1) NEP(2) trap enables IOE..IXE(8-12) IDE(15) FZ16(19)
/// RMode(22-23) FZ(24) DN(25) AHP(26).
pub const arm_control_mask: u32 = 0x07c8_9f07;
pub const arm_expected_control: u32 = 0;
pub fn readControl() u32;                 // stmxcsr / mrs fpcr (asm as in the probe); 0 when unsupported
pub fn controlIsDefault(arch: std.Target.Cpu.Arch, control: u32) bool; // pure, testable for both arches
pub fn assertDefault(comptime site: []const u8) void;
```

- `readControl` x86_64: `var value: u32 = undefined; asm volatile ("stmxcsr
  %[dst]" : [dst] "=m" (value));`. aarch64: `const v = asm volatile ("mrs
  %[ret], fpcr" : [ret] "=r" (-> u64)); return @truncate(v);`. Both were
  compiled on Zig 0.17.0 (x86_64 Debug self-hosted and LLVM, aarch64-macos
  LLVM).
- `assertDefault(site)`: compiled out unless `std.debug.runtime_safety`
  (Debug, ReleaseSafe) and `supported`. On mismatch:
  `logging.core.err("FP environment is not the IEEE default at {s}:
  control=0x{x:0>8} expected=0x{x:0>8} mask=0x{x:0>8}", ...)`, then
  `@panic("FP environment changed (FTZ/DAZ/rounding/traps); simulation
  determinism requires the IEEE default")`. It is a debug assertion: the
  ReleaseSafe soak (52C) and the replay runner in ReleaseSafe exercise it.
  ReleaseFast pays nothing.
- **Call sites** (exactly these):
  1. `SimulationPipeline.update` entry (`simulation_pipeline.zig:1009`),
     `fp_env.assertDefault("simulation step")`: every fixed step on the
     owner thread.
  2. `thread_system.zig` `workerMain` (`:1082`) before `workerLoop`,
     `fp_env.assertDefault("thread worker start")`. POSIX threads inherit
     the creator's FP environment at spawn, so this catches a dependency
     that changed the main thread's MXCSR/FPCR before `ThreadSystem.init`.
     Jobs are framework code and call no dependencies, so a per-batch check
     is not added.
  3. The Slice 51 background-lane thread entry (`background_lane.zig`),
     `fp_env.assertDefault("background lane")`, before the first `work`
     wait. Slice 65B's back-graph patch and Slice 65C's worldgen jobs run on
     that thread and feed simulation state, so the lane is held to the same
     environment as the workers. Slice 65A's `lowerCurrentThreadPriority`
     runs at the same entry; 64A and 65A both edit it, so whichever lands
     second rebases. If 51 has not landed when 64A lands, 51 adds this call
     in its own change (Checklist additions (k)).
  4. 64C `HeadlessSession.init` (by that slice).
- An observed failure is a defect. The fix is to restore the environment at
  the dependency boundary that changed it, cited in a code comment. The check
  is never widened.

**Allocation and threading.** No allocation is added. Every helper is pure or
reads one register. The alpha hold is a main-thread presentation field.

### Checklist

- [ ] **A1 alpha hold.** `presentation_hold`, `presentationAlpha`,
      `onPause`/`onResume`/`update`/`render` changes. Remove the resync APIs
      listed in A1 and their tests. Rename the replay flag constant and doc to
      `pause_boundary_before_step` (`replay.zig`, Slice 51 `replay_capture.zig`
      if landed). Tests in `game_demo_state.zig`, using the Slice 49
      determinism harness:
  - [ ] `test "pause and resume leave the simulation checksum trace unchanged"`
        replaces Slice 49's `test "pause resync changes the simulation
        checksum"`. Run A: 120 scripted steps with `onPause`/`onResume`
        between steps 99 and 100. Run B: the same without. The per-step
        `simulationChecksum()` traces are equal.
  - [ ] `test "pause holds the presentation alpha until the next executed
        step"`: `onPause` → `presentation_hold`; `onResume` keeps it;
        `update` clears it; `presentationAlpha(true, 0.25) == 1`,
        `presentationAlpha(false, 0.25) == 0.25`.
  - [ ] `test "pause does not move the sim view"`: `simViewRect()` before
        `onPause`, after `onResume`, and after the next step equals an
        unpaused run's.
  - [ ] Slice 49's `test "replay recorded from a run verifies against a fresh
        run"` still passes with the pause boundary flag set.
- [ ] **A2 policy.** `math.min`/`math.max`, generic `math.clamp`, parameter
      renames, migration of every `src/game/**` non-test `@min`/`@max` and
      `std.math.clamp` site. Tests in `math.zig` on runtime (`var`) inputs:
  - [ ] integer parity: `min`/`max` equal `@min`/`@max` in value and
        `@TypeOf` for (u32, comptime 200 → u8), (usize, u16), (i32, i32),
        and `@Vector(4, i32)`;
  - [ ] float bits: `min(-0, +0) = 0x00000000`, `min(+0, -0) = 0x80000000`,
        `max(-0, +0) = 0x00000000`, `max(+0, -0) = 0x80000000`;
        `min(NaN, 1) = 1`, `min(1, NaN)` is NaN; the same table on
        `simd.Float4` lanes, bit-equal to `simd.minFloat4`/`maxFloat4` on the
        same inputs (the delegation); and the comptime evaluation of each row
        equals the runtime one;
  - [ ] `clamp` keeps branch semantics for `f32` (NaN propagates; `clamp(-0,
        +0, 1)` returns `-0`) and works for `i32`/`u16` with literal bounds;
        `clamp(v, NaN, 1)` does not trip the `!(lower > upper)` assert (the
        inverted-range assert itself is a debug panic, covered by review like
        `std.math.clamp`'s).
- [ ] **A2 lint.** `GAME_ONLY_PATTERNS` with `RAW_MINMAX_GAME` and
      `STD_MATH_CLAMP_GAME`; `STD_MATH_TRANSCENDENTAL` in
      `SRC_ONLY_PATTERNS` with the `src/core/math.zig` exemption. Update the
      module docstring rule list.
- [ ] **A3.** `math.floatKeyBits` + the `pathfinding/types.zig:825`
      migration. Tests: NaN `0xffc00000`, `0x7fc00000`, and `0x7f800001`
      all map to `0x7fc00000`; `-0.0` maps to `0`; `1.5` maps to its raw bits;
      a path key built from goal `(-0.0, 3)` equals one from `(+0.0, 3)`.
- [ ] **A4.** `src/core/fp_env.zig`, registered in `src/tests.zig`, and the
      step-entry, worker-start, and lane-start call sites (the lane site
      only if 51 has landed; otherwise addition (k)). Tests:
  - [ ] `controlIsDefault(.x86_64, c)`: `0x1f80` and `0x1fbf` (all status
        flags) true; `0x9f80` (FZ), `0x1fc0` (DAZ), `0x3f80` (RC), and
        `0x1f00` (IM unmasked) false.
  - [ ] `controlIsDefault(.aarch64, c)`: `0` true; `1<<24` (FZ), `1<<25`
        (DN), `1<<22` (RMode), `1<<8` (IOE trap), and `1<<1` (AH) false;
        `1<<4` (a bit outside the mask) true.
  - [ ] On a supported host, `controlIsDefault(builtin.cpu.arch,
        readControl())` is true in the test runner (skip otherwise).
  No test writes MXCSR/FPCR.
- [ ] **Docs.**
  - `docs/simulation-tiers-and-pipeline.md` Determinism Contract: pause is
    simulation-invisible; the pause boundary flag; the float min/max/clamp
    rules; `floatKeyBits`; the FP environment assumption and where it is
    asserted.
  - `docs/coding-standards.md`: "Simulation float rules" (A2/A3) and the
    three lint rules.
  - `docs/architecture.md` Coordination Boundaries: pause freezes
    presentation, never simulation state.

### Acceptance checks

- [ ] `zig build verify` passes. `idiom-lint` reports zero
      `RAW_MINMAX_GAME`/`STD_MATH_CLAMP_GAME`/`STD_MATH_TRANSCENDENTAL` hits,
      and each rule fires on a temporary, uncommitted edit (`@max(` in
      `src/game/systems/collision.zig`, `std.math.clamp(` in
      `src/game/contact_query.zig`, `std.math.atan(` and `std.math.asinh(` in
      `src/game/player.zig`).
- [ ] The pause trace test passes, and `grep -rn syncPreviousPosition src/`
      returns nothing.
- [ ] `zig build test` passes in Debug and with `-Doptimize=ReleaseSafe`
      (FP assertion live, no trip), and with `-Doptimize=ReleaseFast`.
- [ ] Manual (display): pause with movers in motion shows a frozen frame,
      resume shows no backward hitch, and the F2 overlay draws in place.
- [ ] Bench gate (ReleaseFast, `ship`, 5 interleaved repetitions, medians,
      before/after on adjacent commits): `zig build -Doptimize=ReleaseFast
      bench -- --group collision`, `--group steering`, `--group perception`,
      `--group spatial_index` at 50k items and `--group ai` at 10k items. No
      median regresses more than 3%, unless the `objdump
      --disassemble=<hot fn>` stream is identical or a strict subset (52D's
      layout-noise rule). Record the table in Status.

---

