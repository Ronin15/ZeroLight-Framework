# Reshape Changelog

Branch: `reshape`

Range: `main..reshape`

Base: `bdc74f6` (`fixed font path on linux`)

Tip: `46e846c` (`fixed agents.md`)

## Summary

`reshape` reorganizes the project around clearer app, render, game, platform,
asset, and core folders. It also moves high-level SDL coordination out of
`main.zig`, gives the state stack explicit ownership of state lifetimes, and
keeps fixed-step timing behavior centered in the executable loop.

## Highlights

- Added `src/app/engine.zig` to coordinate SDL app flow, event handling, pause
  policy, rendering, debug overlay, assets, and state-stack dispatch.
- Reworked `StateStack` and `StateTransitions` in `src/app/state.zig` so states
  are allocated, destroyed, and transitioned through a single stack owner.
- Slimmed `src/main.zig` down to the executable entry point and high-level
  fixed-step timing loop.
- Reorganized source files into `src/app/`, `src/render/`, `src/game/`,
  `src/platform/`, `src/assets/`, and `src/core/`.
- Split the demo player out of the demo state and moved game-specific state code
  under `src/game/`.
- Added aggregate test coverage through `src/tests.zig` and kept `src/root.zig`
  limited to math aliases and compile coverage.
- Moved GPU smoke implementation details under `src/platform/` while keeping
  `src/gpu_smoke.zig` as the executable wrapper.
- Updated project metadata and repo guidance to match the reorganized source
  layout.

## Commit List

- `bce26b8` reshaping
- `3af34ec` further changing shape
- `7ba0c5f` final reshaping
- `a3df910` code review found some state transition issues and docs mismatch
- `c1f3128` re-org and final go forward shape.
- `cf7ea4f` moved player code out of demo state and adjusted the tests
- `162690d` changed build behavior back to default and made release safe and option to be toggled.
- `78bf001` more cleanup
- `46e846c` fixed agents.md
