## Slice 53B: UI Widget Toolkit, Menu Migration, And HUD Primitives

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: one data-oriented widget toolkit every game uses for menus and HUDs:
screens declared once with enum widget identity, anchor/stack layout in
logical space, keyboard and gamepad focus driven only by named `Action`s, a
theme loaded from data, and clipped scrolling. The main menu, settings
(interim), pause, and loading screens move onto it, `menu_view.zig` is
deleted, the pause screen becomes an interactive menu, and a demo HUD proves
the HUD primitives. Allocation-free after warmup.

### Current foundation

- `src/game/menu_view.zig` is the only toolkit: wrap-around
  `changeSelection` and a fixed vertical `renderList`.
- `MainMenuState`, `SettingsMenuState`, `PauseState` (a non-interactive
  overlay whose prompt says Esc/B quits the app), and `LoadingState` each
  hand-draw with `PreparedText`.
- `src/app/state.zig`: `handle_event(*anyopaque, *const SDL_Event,
  *StateTransitions)`; `TransitionApplyResult` carries only
  `quit_requested`; `StateStack.render` assigns `ui_stack_order` and walks
  down while `render_below` holds.
- `src/app/input.zig` `actionForPressEvent` is called by every menu.
- `src/app/engine.zig` filters events before dispatch, skips the router for
  consumed events, applies pause/resume through `FrameCommands`, and tops up
  the overlay after state render. `PauseController` owns `resumeActive` and
  the time-loop reset.
- `src/render/renderer.zig` `k_overlay_command_headroom` and
  `k_stacked_state_ui_headroom` (a hand-sized guess at stacked menu
  content); `render_prep.spriteCommandCapacity` adds the latter.
- `RuntimeAssets.sprite(id)` and atlas metadata resolve icon sources in
  O(1); `AssetReferenceStore` holds per-entity sprite refs.
- Slice 53A: labels, font roles, layout epoch, clipped submit facades.

### Architecture notes

- Screens are retained, state-owned, and declared once as data with enum
  widget identity; no string IDs, callbacks, or per-frame identity hashing
  (`.claude/rules/memory-performance.md`). Focus moves synchronously in
  `handleEvent` so consumption is decided at event time; activations become
  typed events the owner drains in `update`. Layout runs only when
  something is dirty.
- Modal focus scoping is the state stack; dialogs are modal states, not
  widgets. Menus act on resolved `Action`s, and states receive the press
  resolved once per event by `Engine` (`.claude/rules/input-state.md`), so
  Slice 44 changes only the table behind it.
- Screens consume UI actions only; pause, the debug toggle, and gameplay
  actions keep their current paths. Pause resume goes through a transition
  request that `PauseController` applies; it never resumes over a menu.
- UI never writes simulation state; HUD widgets read gameplay values and
  push them on change. UI-originated gameplay requests arrive with Slice
  57B. HUD and screen draw caches are render-side state, never `DataSystem`
  (`.claude/rules/simulation.md`, `.claude/rules/render.md`).
- Per-screen capacity is the screen's own widget enum; draw reservation is a
  bound fixed at build time, never live text length; the stacked-UI
  headroom guess is retired so every reserve term is a build-time bound or
  the overlay headroom (`.claude/rules/budgets-capacities.md`). Draws stay in
  nondecreasing `RenderOrder` (`.claude/rules/render.md`).
- The theme is a developer asset: strictly parsed at startup and fatal when
  missing or invalid, like atlas sidecars (`.claude/rules/assets-audio.md`).
- `LoadingState` covers startup and session load. A world created in play
  (Slice 74) never blocks other worlds' stepping, so any progress it shows
  uses HUD primitives, not a modal that halts the session
  (`.claude/rules/engine-design.md` § Target scale).
- Main thread, serial; cost is per widget and fixed per screen.
- Documented behavior changes: Esc/B in pause resumes instead of quitting;
  Esc on the main menu confirms before quitting.
- Provides: the toolkit, `EventContext`, confirm dialog, and HUD that 54
  (toggle/choice), 44 (`list`), 46, 57B, 67A–67C, and 67E extend.
- VoidLight reference: `UIManager` component/layout/style subset and
  `HudController` dirty-compare pushes; not its string IDs, callbacks,
  theme map, singleton, mouse handling (67A), or flow/grid layouts.

### Checklist

- [ ] Pure layout solver (anchors, fit/fixed/fill, stack gap/padding/cross
      align, scroll offset, rounding, UI-scale multiplier) with tests.
- [ ] Pure focus navigation (wrap, skip hidden/disabled, hstack left/right,
      value widgets consume left/right, auto-scroll) with tests.
- [ ] `UiScreen` shell: build validation errors, action handling and repeat
      policy, bounded event queue with overflow drop, text truncation on
      UTF-8 boundaries, setters; tests.
- [ ] Draw passes with clipped scroll children; CPU-only renderer tests for
      order, focus highlight, clipping, and a bound unchanged by text
      length.
- [ ] Retire `k_stacked_state_ui_headroom`; reserves are per-screen bounds
      plus the overlay headroom; `FailingAllocator` proofs for a
      gameplay-only frame and gameplay → pause → confirm, each with the
      overlay top-up.
- [ ] `FailingAllocator` proofs: warmed render, action handling and event
      drain, a dirty layout pass, a lengthened label.
- [ ] Theme module and shipped `assets/ui/theme.zon`, parsed in tests;
      unknown field, bad version, and bad color rejected.
- [ ] `EventContext` and a resume-gameplay transition request in
      `state.zig`; per-event press resolution and resume apply in `Engine`;
      every state moves to the new signature; tests.
- [ ] Engine loads the theme, feeds its fonts to labels, exposes it to
      states.
- [ ] Main menu, interim settings, pause (Resume / Quit Game with confirm),
      and loading screens migrated; confirm dialog state; `menu_view.zig`
      deleted; keyboard and gamepad test pairs ported.
- [ ] Demo HUD (depth gauge, level and destroyed labels, player portrait),
      updated only on change and never consuming input; tests.
- [ ] Layout-fit tests: each migrated screen fits the logical canvas.
- [ ] Bench groups `ui-layout` and `ui-screen-draw`, each at three widget
      counts far enough apart to show the shape.
- [ ] Docs: `docs/state-stack-and-input.md` (EventContext, menu contract,
      pause menu, Esc/B changes, resume request);
      `docs/rendering-assets-shaders.md` UI toolkit; `docs/architecture.md`
      source layout and UI ownership; `src/tests.zig`.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `ui-layout` and `ui-screen-draw` benches run and show cost linear in
      widget count.
- [ ] Manual (display): every migrated screen and dialog is navigable by
      keyboard and gamepad; F2 still toggles over menus; P/Start and Esc/B
      resume from pause; Quit Game confirms; the HUD tracks digging and
      destroying.
- [ ] Ported keyboard/gamepad activation tests reach the pre-migration
      outcomes.
- [ ] Review: `src/game/ui/` has no string IDs, callbacks, hash lookups,
      `render/gpu/*` imports, or SDL handles; no reserve term depends on
      live text length.
