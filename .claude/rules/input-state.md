---
paths:
  - "src/app/**"
  - "src/game/*_state.zig"
  - "src/game/menu_view.zig"
  - "src/main.zig"
---

# State Stack And Input

How it works: `docs/state-stack-and-input.md`.

- `main.zig` never calls state methods; `Engine` builds contexts and
  `StateStack` dispatches.
- Change state through `StateTransitions` (applied after dispatch); use
  `StateStack` directly only in bootstrap. Use `replaceOwned*` only when the
  state must be allocated before enqueueing.
- Menus never construct catalog-dependent gameplay states; go through
  `LoadingState`.
- `StatePolicy.gameplay` (set only by `state_policy.gameplay`) is the single
  source of "active gameplay". Pause enters only when gameplay is active and is
  never applied over menus; lower states get passes only as policy allows.
- Never advance gameplay on a non-rendering frame or run fixed update in render
  cadence.
- Named-action routing stays separate from raw `handleEvent`. Return `true`
  when the event is consumed; consumed events produce no `FrameCommands`.
- Gameplay reads `InputState`; app commands stay in `FrameCommands` and engine
  code. Never mix held input with one-frame commands.
- Menus resolve presses via `actionForPressEvent` and act on `Action`.
- Held-gameplay UP is always accepted; DOWN is blocked by any modal or opaque
  state in the active path.
- On gameplay-context loss, pause, modal block, or pad disconnect, call
  `releaseHeldGameplay()`, never `releaseMovement()` alone.
- One active gamepad at a time: filter pad events by active id before
  `handleEvent` and routing. Gamepad shares the keyboard's `Action` and routing
  machinery.
- Keyboard and stick movement is clamped per axis, not normalized.
