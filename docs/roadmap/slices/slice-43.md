## Slice 43: SDL3 Gamepad/Controller Support

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: standalone (app/input layer)

**Status: landed (runtime behavior + tests + docs), manual hardware
verification pending.** This is app/input-layer work, independent of the
AI/render tracks (33, 35, 37–38, 40, 42, 45) — no ordering dependency either
way.

Goal: single active-device gamepad support that mirrors the existing
keyboard `Action` model 1:1 with default button bindings, adds true analog
left-stick movement (deadzone + normalized magnitude, not digital d-pad
synthesis), and hot-plug add/remove handling with a clean fallback to
keyboard — no rebind UI (defaults only, a later slice).

### Current foundation

- `src/app/input.zig`'s device-agnostic `Action` enum, `KeyBinding`/
  `default_key_bindings`, `InputState` (held actions + `movementVector`),
  `FrameCommands` (one-frame latched commands), and the private
  `isGameplayAction`/`isCommandAction` classifiers already existed and needed
  no reshaping — only extension.
- `src/app/input_router.zig`'s `InputRoutingPolicy` (gameplay/modalUi/
  passThroughOverlay/opaqueScreen) and `routeEvent` already gated keyboard
  events through per-state action contexts.
- The `sdl_c` TranslateC module (`src/platform/sdl_c.h`) already exposed
  the full SDL3 gamepad API; `init_flag_names` already listed
  gamepad/joystick flag names for debug logging.

### Architecture notes

- New `src/app/gamepad.zig`: `GamepadManager` owns at most one open
  `*SDL_Gamepad` + its `SDL_JoystickID`. Pure decision logic
  (`shouldAdopt`/`isActiveDevice`/`pickFallback`) is unit-tested against
  synthetic `SDL_JoystickID` values; `SDL_OpenGamepad`/`SDL_GetGamepads`/
  `SDL_CloseGamepad` glue is thin and untested (no real/virtual hardware in
  CI, same posture as the display-gated `gpu-smoke` probe).
  `handleDeviceEvent` reacts to `SDL_EVENT_GAMEPAD_ADDED`/`_REMOVED`,
  returning `enum { none, connected, disconnected }`.
- `src/app/input.zig` gained `GamepadButtonBinding`/`default_gamepad_bindings`,
  `actionForGamepadButton`, and `actionForPressEvent` (resolves a fresh
  key-down or gamepad-button-down event to an `Action` in one call — used by
  menu states). `InputState` gained `gamepad_stick_x_raw`/`gamepad_stick_y_raw`,
  `handleGamepadAxis`, and a scaled-radial-deadzone `movementVector` that adds
  the normalized stick vector to the keyboard digital direction and clamps
  each axis independently to `[-1, 1]` (deliberately not clamping combined
  length, to avoid changing keyboard-only sqrt(2) diagonal feel).
  `releaseMovement` now also zeroes the raw stick fields; a new
  `releaseGamepadInput` additionally clears held dig actions for the
  disconnect path. `FrameCommands` gained a public `press` setter mirroring
  `InputState.setHeld`.
- `src/app/input_router.zig` factored a shared `routeAction` helper (policy
  gate + held-vs-one-frame classification) reused by keyboard key events and
  new `SDL_EVENT_GAMEPAD_BUTTON_DOWN`/`_UP` cases (gamepad buttons never
  repeat). A new `SDL_EVENT_GAMEPAD_AXIS_MOTION` case, gated by
  `policy.allowsContext(.gameplay)`, forwards only
  `SDL_GAMEPAD_AXIS_LEFTX`/`_LEFTY` to `InputState.handleGamepadAxis`.
- `src/game/main_menu_state.zig` and `src/game/settings_menu_state.zig` swapped
  their raw `SDL_EVENT_KEY_DOWN` + `actionForKey` checks for the single
  `inputFile.actionForPressEvent(event) orelse return false` call, so D-pad
  nav / South confirm / East cancel work with no per-state gamepad branching.
- `src/app/engine.zig`: `sdl_flags` now includes `SDL_INIT_GAMEPAD`; `Engine`
  gained a `gamepad: GamepadManager` field, initialized via `openInitial()`
  right after `sdl_context` and torn down in `deinit()` before
  `sdl_context.deinit()`; `handleEvents` reacts to
  `SDL_EVENT_GAMEPAD_ADDED`/`_REMOVED` and calls
  `self.input.releaseGamepadInput()` on a `.disconnected` result.
- No changes were needed in `src/game/player.zig`, `src/game/audio_controller.zig`,
  or `src/app/pause_controller.zig` — all three already consumed
  `movementVector()`/`releaseMovement()` through the existing device-agnostic
  contract.
- SDL3 header ground truth used during implementation: `SDL_GamepadButtonEvent.button`
  and `SDL_GamepadAxisEvent.axis` are raw `Uint8` fields (translated to Zig
  `u8`); `SDL_GamepadButton`/`SDL_GamepadAxis` themselves translate to plain
  `c_int` (not a genuine Zig `enum`) because `SDL_GAMEPAD_BUTTON_INVALID`/
  `SDL_GAMEPAD_AXIS_INVALID` are `-1`, so translate-c falls back to an integer
  alias with comptime constants. The correct cast at every call/construction
  site is therefore a plain `@intCast` between the `u8` event field and the
  `c_int` binding/comparison type — never `@fromBackingInt` (formerly
  `@enumFromInt`).

### Checklist

- [x] `src/app/gamepad.zig` (new): `GamepadManager` device lifecycle + pure-function
      unit tests; registered in `src/tests.zig`.
- [x] `src/app/input.zig`: gamepad button binding table, `actionForGamepadButton`,
      `actionForPressEvent`, analog stick fields/deadzone/`handleGamepadAxis`,
      `movementVector` rewrite, `releaseMovement` extension, `releaseGamepadInput`,
      `FrameCommands.press`; tests for every binding, event shape, deadzone case,
      and combination case.
- [x] `src/app/input_router.zig`: shared `routeAction`, gamepad button/axis
      routing cases; tests mirroring keyboard across all four
      `InputRoutingPolicy` presets, plus axis gating/no-op tests.
- [x] `src/game/main_menu_state.zig` / `src/game/settings_menu_state.zig`:
      swapped to `actionForPressEvent`; extended existing named-action tests
      with an equivalent gamepad-driven pass.
- [x] `src/app/engine.zig`: `SDL_INIT_GAMEPAD` flag, `GamepadManager` field +
      init/deinit wiring, device-add/remove handling in `handleEvents`.
- [x] Docs updated: this section, `docs/state-stack-and-input.md` `## Gamepad`
      section (binding table, deadzone/analog contract, hot-plug behavior),
      `docs/architecture.md` ownership bullets and input-flow sentence.

### Acceptance checks

- [x] `zig build verify` (check + test + shader compile + atlas lint) passes.
- [x] All tests listed in the Checklist above are present and passing under
      `zig build test`.
- [x] Docs updated as listed above.
- [ ] Manual hardware verification (no headless virtual-gamepad harness exists
      in this repo, so this is a follow-up outside the automated gate):
      connect a real controller and confirm (a) an already-connected
      controller is picked up automatically at startup, (b) movement feels
      analog through the full deflection range, (c) every binding in the
      table above matches actual button presses, (d) mid-game unplug releases
      held movement/dig state cleanly and falls back to keyboard with no stuck
      input, (e) plugging in a second controller while one is active does not
      steal input from the first.

