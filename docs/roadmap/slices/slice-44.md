## Slice 44: Input Rebinding And Extended Gamepad Controls

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 43](slice-43.md), [Slice 53B](slice-53b.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: players rebind every rebindable `Action` on keyboard and gamepad
without a recompile, the right stick and triggers become bindable inputs,
custom bindings persist across launches in Slice 54's settings file, and
every prompt and binding cell names the active device's own keys or buttons
(keyboard, Xbox, PlayStation, Nintendo). Bindings are app preferences: they
resolve to `Action` before gameplay, replay, or the checksum see input, so
nothing here touches simulation.

### Current foundation

- `src/app/input.zig`: `default_key_bindings` (keycode-based) and
  `default_gamepad_bindings` are comptime const tables; `actionForKey`,
  `actionForGamepadButton`, and `actionForPressEvent` scan them. There is no
  runtime-mutable table.
- `src/app/input_router.zig`: `GAMEPAD_AXIS_MOTION` forwards only
  `LEFTX`/`LEFTY`; right stick and trigger events arrive and are dropped.
- `src/app/gamepad.zig` `openDevice` already queries `SDL_GetGamepadType` at
  adoption (debug log only).
- `docs/state-stack-and-input.md` still says there is no rebind UI.
- Provided by earlier slices when this lands: 53B's `EventContext` press is
  resolved once per event by `Engine` (the single place bindings are read);
  54's Engine-owned `SettingsStore` with a versioned file and upgrade chain.

### Architecture notes

- Bindings live in Slice 54's settings, never in saves (Ground Rules); the
  schema version bumps relative to its live value (Table T2,
  `.claude/rules/simulation.md` § Persistent data).
- The const default tables stay the reset source. An `Action` appended by a
  later slice (56, 57, 60, 69C) becomes a Controls row with its default from
  the const tables and no schema bump; a file that omits it keeps the
  default.
- One input maps to at most one action, enforced on edit, on load, and by a
  test over the default tables. A conflicting capture is rejected with a
  message; nothing is silently shadowed or auto-swapped.
- Navigation, confirm, back, and pause keep at least one binding per device
  category. The debug-overlay toggle is not rebindable.
- Capture consumes every candidate event while open so nothing reaches
  `FrameCommands`; it accepts fresh presses only (never a repeat or the
  press that opened it), filters by device category, and raw Escape always
  cancels even when `quit` is rebound. A gamepad-only user can leave capture
  without a keyboard.
- Right stick and triggers are routed under the same `InputRoutingPolicy`
  gate as the left stick; right-stick meaning stays a thin mapping, not a
  new gameplay contract (`.claude/rules/input-state.md`).
- Device labels and prompt text are rebuilt only on a binding, device, or
  pad-family change, never per frame
  (`.claude/rules/memory-performance.md`).
- Resolution, capture, and a warmed Controls list are allocation-free.
- Provides: the runtime binding table and `list` widget that 67A (pointer,
  scancodes) and 67B (denied cue) extend; the last-used device and prompt
  epoch that 67A extends with the pointer.
- VoidLight reference: `InputManager` capture/label policy
  (`InputManager.cpp:239-400`, `:925-1006`); not its polling, JSON key maps,
  mouse or stick-direction bindings, separate bindings file, or singleton.

### Checklist

- [ ] (added by Slice 67) Capture rejects every repeat press, including 67A's
      synthesized pad repeats, and captures only key-down, pad button-down,
      or a trigger crossing (67A's left-stick menu presses are consumed,
      never captured).
- [ ] Runtime binding table owned by settings, reset to defaults, resolvers
      reading it; tests that a rebound action resolves and reset restores.
- [ ] Controls screen (from Settings) on a new `list` widget, plus the
      capture modal; keyboard and gamepad tests for category filter, repeat
      rejection, raw-Escape cancel with `quit` rebound, clear, timeout,
      conflict message, and the protected-action guard.
- [ ] Right-stick and trigger bindings with policy-gated router cases; tests
      mirroring the left-stick gating tests.
- [ ] Settings schema bump with its upgrade step and binding validation;
      tests that a previous-version file upgrades keeping audio/video, the
      new version round-trips, and each rejection reason fails.
- [ ] Default-table one-action-per-input test.
- [ ] Pad family and button/key label tables (pure, tested); SDL label glue
      stays thin.
- [ ] Last-used device and prompt epoch; menus' hint footers become
      binding- and device-aware; tests.
- [ ] `FailingAllocator` proofs: resolution, capture events, warmed `list`
      render.
- [ ] Docs: `docs/state-stack-and-input.md` `## Gamepad` and a new
      `## Rebinding` (remove "no rebind UI yet"); `docs/architecture.md`
      input bullets; Table T2.
- [ ] Add the new-action binding-defaults rule to
      `.claude/rules/input-state.md` when this lands.

### Acceptance checks

- [ ] A rebound action resolves at runtime with no recompile; right stick
      and triggers drive their bound actions.
- [ ] Keyboard-only and default-binding behavior is unchanged.
- [ ] Rebound bindings survive a restart; a previous-version settings file
      upgrades with audio and video preserved and default bindings filled.
- [ ] Escape cancels capture even when `quit` is bound elsewhere.
- [ ] Manual with hardware: prompts and binding cells show Xbox,
      PlayStation, and Nintendo names for the connected pad, and keyboard
      names after keyboard use.
- [ ] `zig build verify` passes.
