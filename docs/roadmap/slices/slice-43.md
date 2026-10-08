## Slice 43: SDL3 Gamepad/Controller Support

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: standalone (app/input layer)

**Status: landed (runtime behavior, tests, docs); manual hardware
verification pending.**

Goal: one active gamepad drives the same device-agnostic `Action` model as
the keyboard, with default button bindings, true analog left-stick movement,
and hot-plug add/remove that falls back cleanly to the keyboard. Rebinding
is Slice 44.

### Current foundation

- `src/app/gamepad.zig` `GamepadManager` owns at most one open pad and its
  `SDL_JoystickID`; pure adoption/fallback decisions are unit-tested, and
  the thin SDL open/close glue is not (no virtual-pad harness).
  `handleDeviceEvent` reports `none` / `connected` / `disconnected`.
- `src/app/input.zig`: `default_gamepad_bindings`, `actionForGamepadButton`,
  `actionForPressEvent` (one resolver for key-down and pad button-down,
  used by every menu), raw stick fields, `handleGamepadAxis`, and a
  scaled-radial-deadzone `movementVector` that adds the stick to the
  keyboard direction and clamps per axis. `releaseHeldGameplay` /
  `releaseGamepadInput` clear held movement, dig, and interact.
- `src/app/input_router.zig`: shared `routeAction` for key and pad button
  events; pad events are filtered to the active pad id before routing;
  `GAMEPAD_AXIS_MOTION` forwards only the left stick, gated by the
  gameplay context.
- `src/app/engine.zig`: `SDL_INIT_GAMEPAD`, the `gamepad` field, device
  add/remove handling, `releaseGamepadInput()` on disconnect.
- SDL3 translate-c fact: `SDL_GamepadButton` / `SDL_GamepadAxis` are plain
  `c_int` aliases (their `INVALID` values are `-1`), and the event fields
  are `u8`, so call sites cast with `@intCast`, never an enum cast.

### Architecture notes

- App/input layer only; no simulation, render, or replay surface.
- One active pad, shared `Action` and routing machinery, per-axis clamping,
  and `releaseHeldGameplay()` on context loss are rules in
  `.claude/rules/input-state.md`.

### Checklist

- [x] `GamepadManager` device lifecycle with pure-decision unit tests.
- [x] Gamepad binding table, press resolver, analog stick, deadzone, and
      release paths in `input.zig`, with tests.
- [x] Router gamepad button/axis cases across all four routing policies,
      with tests.
- [x] Main and settings menus resolve presses through `actionForPressEvent`,
      with gamepad test passes.
- [x] Engine gamepad init/deinit and hot-plug handling.
- [x] Docs: `docs/state-stack-and-input.md` `## Gamepad`,
      `docs/architecture.md` input ownership.

### Acceptance checks

- [x] `zig build verify` passes.
- [x] Checklist tests pass under `zig build test`.
- [x] Docs updated.
- [ ] Manual hardware check with a real controller: (a) a pad connected at
      startup is adopted; (b) movement is analog across full deflection;
      (c) every default binding matches its button; (d) unplugging mid-game
      releases held movement and dig with no stuck input and falls back to
      the keyboard; (e) a second pad does not steal input from the first.
