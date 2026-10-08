## Slice 67A: Pointer Input, Menu Hold-To-Repeat, And Scancode Bindings

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal:
- Every toolkit screen works with a mouse: hover focuses, left click
  activates, sliders drag, the wheel scrolls scroll containers and lists,
  and HUD widgets can show hover tooltips. Letterbox bars never hit.
- Gamepad users get held-D-pad and left-stick menu navigation at a fixed
  repeat cadence; keyboard keeps the OS key repeat.
- Keyboard bindings are physical scancodes, so WASD stays WASD-shaped on
  AZERTY and Dvorak; existing keycode bindings migrate once, against the
  real OS keymap, with no data loss.

### Current foundation

- `src/app/resolution.zig`: pure `windowToDrawable`, `drawableToLogical`
  (null in letterbox bars), and `windowToLogical`, tested for HiDPI and
  letterbox. There is no logical→window helper.
- `src/render/renderer.zig` keeps `current_presentation`, refreshed from the
  acquired swapchain size each frame.
- `src/app/engine.zig` `handleEvents` uses one routing policy per batch,
  gates delivery, skips the router for consumed events, and applies
  transitions after the loop.
- `src/app/input.zig` bindings and `actionForKey` are keycode-based
  (`SDLK_*`, `event.key.key`); SDL never synthesizes gamepad button
  repeats; the router never latches a repeat into `FrameCommands`; the left
  stick feeds movement only, under the gameplay context.
- SDL 3.4: window-relative float mouse coordinates, whole-tick wheel deltas
  with a flipped-direction flag, mouse-leave and keymap-changed events,
  scancode↔keycode lookups.
- `SDL_Init(VIDEO)` does not guarantee the real keymap: until a backend
  installs one SDL answers from its US default, and on Wayland the seat
  keymap arrives asynchronously, before keyboard focus is delivered. A
  keycode→scancode migration at load would bake in a US mapping.
- From earlier slices: 53B's retained widget rects, single focus setter,
  one scroll level, `EventContext`, non-consuming HUD; 44's runtime
  bindings, `list` widget, capture modal, last-used device, and prompt
  epoch; 54's settings upgrade chain.

### Architecture notes

- App and UI only; no simulation, replay, or checksum change (Slice 67).
- `Engine` resolves each pointer event to logical space once and passes it
  in the per-event context; `src/game/ui/` never sees SDL types
  (`.claude/rules/input-state.md`, `.claude/rules/engine-design.md`).
- Hover focuses only on motion, so a stationary cursor never steals focus
  from keyboard or gamepad navigation; there is one focus highlight for
  every device. Motion is never consumed (pass-through overlays keep
  tracking), and the non-interactive HUD never consumes input.
- The wheel scrolls but never edits a value; scrollbars are not
  interactive.
- Synthesized menu presses go only to the state stack, never the router or
  `FrameCommands`; at most one stick press and one repeat per frame, no
  catch-up after a hitch; any applied transition, focus loss, pad
  disconnect, or loss of the UI context disarms. The left-stick menu
  gesture is fixed behavior, not a bindable input.
- Rebind capture treats a click as cancel, ignores every repeat, and never
  captures a stick menu press; mouse buttons are not bindable.
- Prompt text treats the pointer as keyboard, so alternating mouse and
  keyboard rebuilds nothing; the cursor hides on gamepad use and shows on
  mouse motion, switching only on device change.
- The settings schema bumps relative to its live value (Table T2). Old
  keyboard entries migrate on the first event that guarantees the real
  keymap; until then scancode defaults apply and no settings write happens,
  so a session that never gains focus leaves the old file intact. A
  migration collision resets only the input section. A load that upgraded
  writes the latest version once, so a later layout change cannot
  re-migrate it.
- Hit testing and repeat cost are fixed per event and per frame,
  independent of content size (`.claude/rules/budgets-capacities.md`).
- Documented behavior change: on non-QWERTY layouts defaults bind physical
  positions; QWERTY is unchanged.
- VoidLight reference: `UIManager::handleInput` hit order, modal swallow,
  press-release click, slider-from-x, tooltip timer
  (`UIManager.cpp:1902-2108`); not its per-frame mouse polling, sorted
  per-frame walk, callbacks, or string IDs.

### Checklist

- [ ] Pointer event vocabulary and a pure SDL-event → pointer resolver
      (inside/outside viewport, bar clicks, non-left buttons, flipped wheel,
      zero ticks), with tests.
- [ ] Renderer window→logical facade (null before first presentation,
      letterbox mapping), CPU-only renderer tests.
- [ ] Engine pointer resolution, leave on mouse-leave/focus-lost, cursor
      visibility on device change; prompt-epoch tests for pointer
      alternation.
- [ ] Pure hit test (topmost wins, invisible skipped, scroll clip, worst-case
      widget count) with tests.
- [ ] `UiScreen` pointer handling: hover-focus on motion only, click per
      widget kind, slider drag, wheel scroll and clamps, consumption rule,
      leave; tests.
- [ ] 44 `list` pointer cells and wheel rows; capture amendments (click
      cancels, motion/wheel consumed, repeats rejected, stick press not
      captured) with tests.
- [ ] Hover tooltips with delay, hide, and canvas clamping; set-text only on
      candidate change; build-time over-long hint error; demo HUD tooltips.
- [ ] Menu hold-to-repeat for pad buttons and the left stick (delay,
      interval, hysteresis, direction change, disarm triggers) with pure
      tests; Engine dispatch through the state stack and disarm on stack
      change, with a modal-state test.
- [ ] Scancode bindings, resolvers, capture, and layout-aware key labels
      with a keymap-change epoch bump; keyboard test helpers set scancodes;
      an AZERTY-shaped event resolves by scancode.
- [ ] Settings schema bump with the deferred keymap-ready migration and
      upgrade write; tests for conversion, unmappable keys, collision reset,
      round-trip, parked-then-completed migration, no write when never
      completed, and exactly-once completion in `Engine`.
- [ ] `FailingAllocator` proofs: warmed pointer events + render, tooltip
      cycle, repeat dispatch, scancode resolution, migration completion.
- [ ] Bench group `ui-pointer-hit` at three pointer-event counts far enough
      apart to show the linear shape.
- [ ] Docs: `docs/state-stack-and-input.md` `## Pointer`, `## Menu repeat`,
      `## Scancode bindings` (layouts, migration, upgrade write), physical
      default wording; `docs/architecture.md` input flow; Table T2;
      `src/tests.zig`.
- [ ] Add the settings migration-freeze rule to
      `.claude/rules/input-state.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `ui-pointer-hit` shows cost linear in event count.
- [ ] Manual (display): every toolkit screen is usable by mouse alone;
      tooltips appear after the hover delay; letterbox clicks do nothing;
      HiDPI and fractional fit windows map clicks correctly.
- [ ] Manual (hardware pad): held D-pad and left stick repeat at the fixed
      cadence; holding through Confirm does not scroll the next screen; the
      cursor hides on pad use and returns on mouse motion.
- [ ] Manual (AZERTY on X11 and Wayland): WASD defaults act on physical
      positions and show "Z/Q/S/D"; an old keycode file migrates once to
      physical keys and is rewritten at the new version.
- [ ] Review: `src/game/ui/` reads only typed context fields, with no new
      SDL types and no per-event allocation.
