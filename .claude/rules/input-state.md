---
paths:
  - "src/app/**"
  - "src/game/*_state.zig"
  - "src/game/menu_view.zig"
  - "src/main.zig"
---

# State Stack And Input

How it works: `docs/state-stack-and-input.md`.

## States

- Entry code never calls state methods; `Engine` builds contexts and
  `StateStack` dispatches.
- State changes go through `StateTransitions` and apply after dispatch; use
  `StateStack` directly only in bootstrap, and `replaceOwned*` only when the
  state must be allocated before enqueueing.
- A state that needs loaded catalogs is reached through `LoadingState`, never
  constructed by a menu.
- `StatePolicy.gameplay` is the single source of "active gameplay". Pause
  applies only over active gameplay, never over menus; lower states receive
  only what policy allows.
- Gameplay never advances on a non-rendering frame, and fixed update never
  runs at render cadence.

## Input

- Named actions route separately from raw `handleEvent`. A handler returns
  `true` when it consumed the event, and a consumed event produces no
  `FrameCommands`.
- Gameplay reads held input from `InputState`; one-frame app commands stay in
  `FrameCommands`. Never mix the two.
- Menus resolve presses with `actionForPressEvent` and act on `Action`, never
  on raw keys or buttons.
- Releasing held input is always accepted; a press is blocked by any modal or
  opaque state in the active path.
- Losing gameplay context (pause, modal block, focus loss, pad disconnect)
  calls `releaseHeldGameplay()`, never `releaseMovement()` alone.
- One gamepad is active at a time: other pads' events are filtered before
  handling and routing, and the gamepad shares the keyboard's actions and
  routing.
- Keyboard and stick movement clamps per axis, never normalizes.
