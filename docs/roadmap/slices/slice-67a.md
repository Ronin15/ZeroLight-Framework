## Slice 67A: Pointer Input, Menu Hold-To-Repeat, And Scancode Bindings

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** App-layer and `src/game/ui/` work. Depends on Slice 53B
(`UiScreen`, retained `rect` column, focus, scroll, `EventContext`), Slice 54
(`SettingsStore` and the `upgradeVNToVN+1` chain), and Slice 44
(`RuntimeInputBindings`, `list` widget, `RebindCaptureState`,
`InputDevice` / `InputPrompts`). Independent of the AI, simulation, and
world-render tracks.

Goal:
- Every 53B / 44 / 54 / 46 screen works with a mouse:
  - hovering a focusable widget focuses it
  - left click activates it
  - sliders drag
  - the wheel scrolls scroll containers and lists
  - HUD widgets can show hover tooltips
- Gamepad users get held-D-pad and left-stick menu navigation with a fixed
  repeat cadence. Keyboard keeps OS key repeat.
- Keyboard bindings are physical scancodes. WASD stays WASD-shaped on AZERTY
  and Dvorak. Existing `settings.zon` keycode bindings migrate once, under a
  settings schema bump, with no data loss.

### Current foundation

- `src/app/resolution.zig:100-128`: pure `windowToDrawable`,
  `drawableToLogical` (returns `null` in letterbox/pillarbox bars), and
  `windowToLogical`. Tests at `:290-326` cover HiDPI and the letterbox.
- `src/render/renderer.zig:291-293`: `resolution_policy` and
  `current_presentation: ?resolution.Presentation`, updated from the acquired
  swapchain size in `updatePresentation` (`:894-912`).
- `src/app/engine.zig:209-255` `handleEvents`:
  - one routing policy per batch (`:216`)
  - `shouldDeliverEvent` gate (`:238`)
  - consumed events skip the router (`:239-242`)
  - `applyTransitions` after the loop (`:244`)
- `src/app/input.zig:35-53`: `default_key_bindings` is keycode-based
  (`c.SDLK_*`). `:202-207` `actionForKey(event.key.key)`, `:219-225`
  `actionForPressEvent`.
- `src/app/input_router.zig:89-92`: keys route on `event.key.key`. `:93-99`:
  gamepad buttons never repeat ("SDL does not synthesize repeat events").
  `:100-109`: the left stick is gated by `.gameplay` and feeds movement only.
  `:146-161` `routeAction` never latches a repeat into `FrameCommands`.
- `src/app/state.zig:479-488`: the `StateStack.handleEvent` top-down walk with
  `events_below`. `:58-60` `TransitionApplyResult`.
- Slice 53B:
  - `UiScreen(W)` with `rect` retained "so pointer hit-testing can be added
    later without restructuring"
  - `flags` packed `u8`
  - `handleAction(ActionPress)` accepting repeat for `menu_*` only
  - one scroll level, with focus auto-scroll
  - `UiEvent(W)` ring of 16
  - the demo HUD (`progress` depth gauge, `image` portrait, labels), which
    never consumes input
- Slice 44: `RuntimeInputBindings.keys: [action_count][2]c.SDL_Keycode`,
  persisted as numeric `.key`, with the note "Layout-independent scancode
  bindings would be a later schema bump (Scaling Gap)". Also:
  - `RebindCaptureState` (fresh presses only, raw Escape cancels,
    Backspace/Delete clears)
  - `list` widget (≤ 64 rows × 3 columns, auto-scroll)
  - `last_input_device: InputDevice = enum { keyboard, gamepad }`
  - `InputPrompts.epoch`
- SDL 3.4 headers:
  - `SDL_MouseMotionEvent` / `SDL_MouseButtonEvent` carry window-relative
    float `x`/`y` (`SDL_events.h:453-485`)
  - `SDL_MouseWheelEvent.integer_y` holds accumulated whole ticks (added in
    3.2.12; the pinned 3.4.18 has it) and `direction` can be
    `SDL_MOUSEWHEEL_FLIPPED` (`:492-506`)
  - `SDL_EVENT_WINDOW_MOUSE_LEAVE` (`:149`), `SDL_EVENT_KEYMAP_CHANGED`
    (`:174`)
  - `SDL_GetScancodeFromKey` / `SDL_GetKeyFromScancode` / `SDL_GetKeyName`
    (`SDL_keyboard.h:231-333`)

### Architecture notes

**Pointer vocabulary** (`src/app/input.zig`, beside `ActionPress`):

```zig
pub const InputDevice = enum { keyboard, gamepad, pointer }; // 44's enum + .pointer (producer: mouse events)

pub const PointerEvent = union(enum) {
    motion: ?resolution.Point,       // null = cursor is outside the logical viewport (bars)
    primary_down: resolution.Point,  // left button down inside the viewport
    primary_up: ?resolution.Point,   // left button up; null when released outside the viewport
    wheel: PointerWheel,
    leave,                           // mouse left the window or the window lost focus
};
pub const PointerWheel = struct { ticks_y: i32, at: ?resolution.Point };
```

- Only the left button is interpreted. Other buttons resolve to
  `pointer = null` and are never consumed. Double-click count is unused.
  Horizontal wheel (`integer_x`) is unused.
- Touch and pen arrive as SDL's synthesized mouse events (SDL default hints)
  and are treated as pointer input with no special casing.
- **Prompt device.** `.pointer` shows keyboard prompt labels.
  `InputPrompts.epoch` bumps only when
  `promptDevice(device) = if (device == .pointer) .keyboard else device`
  changes, so alternating mouse and keyboard rebuilds no hint text.

**Engine resolution** (`Engine.handleEvents`, once per delivered event,
alongside 53B's `press`):

- New facade `Renderer.windowPointToLogical(x: f32, y: f32) ?resolution.Point`.
  - It returns `null` before the first presentation.
  - Otherwise it calls `resolution.windowToLogical(.{x, y}, p.policy,
    p.window_size, p.drawable_size) catch null` on `current_presentation`
    (`catch null`, never `unreachable`).
  - During a live drag-resize, the mapping uses the last presented frame. One
    frame of staleness is accepted; the next `endFrame` refreshes it.
- Mapping from SDL events to `PointerEvent`:

  | SDL event | `pointer` |
  | --- | --- |
  | `MOUSE_MOTION` | `.motion = map(x, y)` |
  | `MOUSE_BUTTON_DOWN`, `button == SDL_BUTTON_LEFT` | `.primary_down = p` if `map` is non-null, else `null` |
  | `MOUSE_BUTTON_UP`, `SDL_BUTTON_LEFT` | `.primary_up = map(x, y)` |
  | `MOUSE_WHEEL` | `.wheel = .{ .ticks_y = if (direction == FLIPPED) -integer_y else integer_y, .at = map(mouse_x, mouse_y) }`; `integer_y == 0` gives `null` |
  | `WINDOW_MOUSE_LEAVE`, `WINDOW_FOCUS_LOST` | `.leave` |

- `timestamp_ns = event.common.timestamp`.
- `device = .pointer` for motion, button, and wheel events. Engine's
  `last_input_device` (44) also updates from these events.
- **Cursor visibility** goes through the new
  `sdl.setCursorVisible(visible: bool)` (`SDL_ShowCursor` / `SDL_HideCursor`):
  - `last_input_device` becomes `.gamepad` → hide.
  - It becomes `.pointer` → show.
  - Keyboard input leaves the cursor as is.
  - The cursor is visible at startup.
  - The call happens only when the device changes, never per frame.

**`UiScreen` pointer handling** (`src/game/ui/screen.zig` plus pure helpers in
the new `src/game/ui/pointer.zig`):

- **New API.**
  - `UiScreen.handleEvent(context: EventContext) bool` is the single entry
    owners call from `State.handleEvent`, replacing their direct
    `handleAction` call. It calls `handleAction(press)` when `press != null`,
    then `handlePointer(context)` when `pointer != null`, and returns their OR.
  - `rectOf(widget: W) Rect` reads the retained rect.
  - `setTooltip(widget: W, enabled: bool) void` sets flag bit `tooltip`. 53B's
    `flags: packed struct(u8)` has spare bits for it.
- **Hit test.** Pure `hitTest(rects, flags, parents, scroll_clip, point) ?u8`.
  - It walks widgets in reverse declaration order: children are declared after
    parents and drawn later, so the last match is on top.
  - It skips invisible widgets.
  - A widget inside the scroll container must also be inside the scroll's clip
    rect.
  - It returns the topmost hit.
  - Cost is O(`k_max_widgets_per_screen` = 64) per event. It is fixed and
    independent of content size.
- **Per-screen pointer state** (fixed fields, no allocation):
  - `hover: u8 = k_none`, `hover_since_ns: u64`
  - `pressed: u8 = k_none` (the widget that received `primary_down`)
  - `drag: u8 = k_none` (slider being dragged)
  - `pointer_at: ?Point`
  - `tooltip: TooltipState`
- **Hover = focus.**
  - On `.motion` whose hit is a visible, enabled, focusable widget different
    from the focused one, focus moves to it through the same internal
    `setFocusInternal` that action navigation uses.
  - There is no auto-scroll on hover-focus: the widget is already under the
    cursor.
  - Focus changes **only on motion events**, so a stationary cursor never
    steals focus back from keyboard or gamepad navigation. This replaces
    VoidLight's "gamepad selection wins over stale hover" rule with an
    event-driven equivalent.
  - Hovering a non-focusable widget or empty space leaves focus where it is,
    so a menu always keeps a focused item.
  - There is no separate hover highlight. The single focus highlight serves
    every device.
- **Click semantics.** `primary_down` on a focusable, enabled hit focuses it
  and sets `pressed`. `primary_up` resolves the press:

  | Widget kind (owner slice) | `primary_down` | `primary_up` over the same widget |
  | --- | --- | --- |
  | `button` (53B) | focus, `pressed` | `activated` |
  | `slider` (53B) | focus, set value from x, `drag = w` | end drag (no extra event) |
  | `toggle` (54) | focus, `pressed` | flip, `value_changed` |
  | `choice` (54) | focus, `pressed` | cycle forward (wrap, skip disabled), `value_changed` |
  | `list` cell (44) | focus (row, column), `pressed` | `list_activated { widget, row, column }` |
  | disabled widget | nothing | nothing (67B adds the `denied` cue) |

  - `primary_up` elsewhere, or `null`, clears `pressed` and `drag` with no
    event.
  - Slider value from x:
    `min + round(clamp((x − track.x) / track.w, 0, 1) × (max − min) / step) × step`.
    It is clamped. `value_changed` fires only when the value changes, on down
    and on each drag motion.
- **Wheel.**
  - `.wheel` at a point resolves the nearest scroll ancestor of the hit
    widget, or the hit itself if it is the scroll or a `list`.
  - Scroll container: `scroll_offset -= ticks_y × k_wheel_rows_per_tick ×
    theme.metrics.row_height × ui_scale`, clamped to
    `[0, max(0, content_h − viewport_h)]`. Then mark arrange-dirty through the
    same path focus auto-scroll already uses.
  - `list` (44): `first_visible_row` moves by `ticks_y × k_wheel_rows_per_tick`
    rows, clamped. Focus does not move. The next navigation press auto-scrolls
    back to the focused row.
  - The wheel never changes slider, toggle, or choice values, so scrolling a
    settings list cannot edit it by accident.
  - With no scrollable target, the wheel is not consumed.
  - There is no scrollbar interaction: clicks on the scrollbar rects are
    consumed and ignored. Wheel and focus auto-scroll are the scroll inputs.
- **List hit-test.** A cell's rect comes from the list rect, row index ×
  row height relative to `first_visible_row`, and the per-column x extents
  that 44's layout computes. Those extents are retained per list at layout
  time.
- **Consumption.** `handlePointer` returns `true` iff the screen is
  interactive (≥ 1 focusable widget, counted at `build()`) and the event is
  one of:
  - a `primary_down` / `primary_up` / `wheel` that hit any visible widget of
    this screen
  - a `primary_up` / `.leave` that ended a `pressed` or `drag`

  `.motion` is never consumed, so pass-through overlays still let the screen
  below track hover. The non-interactive HUD always returns `false`, keeping
  53B's "HUD never consumes input".
- `.leave` clears `hover`, `pressed`, `drag`, and the tooltip.
- **Capture state (44 amendment).** While `RebindCaptureState` is open:
  - a `primary_down` cancels the capture, exactly like raw Escape, and is
    consumed
  - pointer motion and wheel are consumed
  - mouse buttons are never bindable

**Hover tooltips** (`src/game/ui/tooltip.zig`, drawn by `UiScreen.render`):

- `TooltipState { widget: u8 = k_none, shown: bool = false, label:
  TextLabelId = .invalid, anchor: Point }`.
- **Candidate.** The hovered widget becomes the candidate when it has
  `flags.tooltip`, is visible, and has a non-empty `hint` (53B's static
  literal). `build()` rejects a tooltip hint longer than 128 bytes with the
  new `error.UiTooltipTooLong` in `UiBuildError`.
- **Show.** `shown` becomes true in `render` once `context.frame_start_ns -
  hover_since_ns >= k_tooltip_delay_ns` (600 ms). `hover_since_ns` resets on
  every motion that changes the hovered widget.
- **Hide.** Any of these hides it: `.motion` to a different widget, `.leave`,
  `primary_down`, any `press`, `setVisible(false)` on the candidate.
- **Placement.** Anchor = pointer + `k_tooltip_offset = {12, 18}` logical px,
  then clamped so the panel stays inside the canvas.
  - Panel padding is `theme.metrics.tooltip_padding = 6`.
  - The label is the `body` role, wrapped at `theme.metrics.tooltip_max_width
    = 320`.
  - Colors: `theme.colors.tooltip_bg` and `theme.colors.text`.
- **Text work.** The tooltip's `TextLabelId` calls `setText` only when the
  candidate widget changes (cold; Wyhash no-op otherwise). It uses the 53A
  `isAlive` re-create rule.
- **Draw.** After the `.text` pass, at the same `RenderOrder.uiInStack(order,
  .text)`. Equal order keeps submission order, so it lands on top.
  - Bound: 1 panel + 4 border + `max tooltip hint bytes` (computed at
    `build()`) is added to `drawCommandBound()`.
- `RenderContext` gains `frame_start_ns: u64 = 0`. Engine passes the
  `frame_start_ns` it already has (`engine.zig:203-207`).
- **First consumer.** The 53B demo HUD (`GameDemoState`):
  - `setTooltip(.depth_gauge, true)` with hint "Depth: current level / deepest
    level"
  - `setTooltip(.portrait, true)` with hint "Player"
  - `GameDemoState.handleEvent` forwards the context to `hud.handleEvent` and
    still returns `false`.
  - Menus with hint footers do not enable tooltips: hover = focus already
    drives their footers.

**Menu hold-to-repeat** (`src/app/menu_repeat.zig`, `MenuRepeat`, an Engine
field):

- **Scope.** Gamepad only. Keyboard keeps OS key repeat (`repeat = true`
  KEY_DOWN events), which respects the user's OS repeat and accessibility
  settings. Only `menu_up/down/left/right` repeat (53B's repeat-accepting set).
- **Constants.**
  - `k_menu_repeat_delay_ns: u64 = 400 * std.time.ns_per_ms`
  - `k_menu_repeat_interval_ns: u64 = 100 * std.time.ns_per_ms` (10 Hz)
  - At most one synthesized repeat per frame. No catch-up after a hitch:
    `next_fire_ns = now + interval` after each fire.
- **State.**
  - `held: ?Action`
  - `source: Source = union(enum) { pad_button: u8, left_stick }`
  - `next_fire_ns: u64`
  - `armed_event: c.SDL_Event` (copy of the arming event, passed as the raw
    event of synthesized repeats)
  - `stick_x_raw: i16`, `stick_y_raw: i16`, `stick_direction: ?Action`
- **Pad button arming.** A delivered `SDL_EVENT_GAMEPAD_BUTTON_DOWN` whose
  resolved `press.action` is a `menu_*` action, while
  `routing_policy.allowsContext(.ui)`, arms `held` with
  `next_fire = timestamp + delay`.
  - The `GAMEPAD_BUTTON_UP` of the same button disarms.
  - Triggers bound to menu actions (44 digital triggers) never arm. This is
    documented.
- **Left-stick menu navigation.** Applies only when
  `!routing_policy.allowsContext(.gameplay) and
  routing_policy.allowsContext(.ui)`, i.e. a menu owns input.
  - `GAMEPAD_AXIS_MOTION` for `LEFTX` / `LEFTY` updates the UI copy of the
    stick. It does not touch `InputState`, which stays `.gameplay`-gated by
    the router.
  - Direction = the sign of the axis with the larger `|raw|`, when that `|raw|
    ≥ k_menu_stick_press_raw: i16 = 16384` (0.5). It is released when both
    axes are below `k_menu_stick_release_raw: i16 = 11469` (0.35).
  - Entering a direction, or changing to a different one while above the press
    threshold, yields a **fresh** synthesized press (`repeat = false`) and
    arms the repeat with `source = .left_stick`. Release disarms.
  - This is fixed, non-rebindable behavior. Slice 44's "do not port
    stick-direction digital bindings" still holds: the stick is not a
    `PadInput`.
- **Dispatch.** After the poll loop and before `applyTransitions`:
  1. A stick fresh press (collected during the loop, at most one per frame)
     dispatches first.
  2. Then `menu_repeat.due(now)` yields at most one repeat.
  3. Both go through `self.states.handleEvent(&armed_event, context)` with
     `press = .{ .action, .repeat }` and `device = .gamepad`.
  4. Synthesized presses never reach the router or `FrameCommands`. A repeat
     never latches a command anyway (`input_router.zig:158`).
- **Disarm triggers:**
  - source release
  - gamepad disconnect (beside `releaseGamepadInput`)
  - `WINDOW_FOCUS_LOST`
  - a batch whose routing policy no longer allows `.ui`
  - any applied transition: new `TransitionApplyResult.stack_changed: bool`,
    set when any replace/push/pop request applied. Engine calls
    `menu_repeat.cancel()` on it. Holding Down through Confirm into a new
    screen does not scroll the new screen until the button is pressed again.
- **Capture state (44 amendment).** `RebindCaptureState` rejects any event
  whose `context.press.repeat == true`. That covers OS key repeats and
  synthesized pad repeats, so a D-pad held into a capture cannot be captured
  as a fresh press.
  - It also accepts a fresh press only when its raw event is a capturable
    input shape: `SDL_EVENT_KEY_DOWN`, `SDL_EVENT_GAMEPAD_BUTTON_DOWN`, or
    `SDL_EVENT_GAMEPAD_AXIS_MOTION` on `SDL_GAMEPAD_AXIS_LEFT_TRIGGER` /
    `RIGHT_TRIGGER` (44's digital triggers). A synthesized left-stick press
    carries its arming `GAMEPAD_AXIS_MOTION` on `LEFTX`/`LEFTY` with
    `repeat = false`; capture ignores it and consumes it (44's "swallows
    everything" rule), so the stick never becomes a binding.

**Scancode keyboard bindings** (`src/app/input.zig`, Slice 44's types
amended):

- **Table types.**
  - `KeyBinding { scancode: c.SDL_Scancode, action }`.
  - `default_key_bindings` uses `c.SDL_SCANCODE_*` for every default present
    at landing: today's A/D/W/S, P, RETURN, SPACE, ESCAPE, F2, arrows, E, Q,
    F, R, plus Slice 60's EQUALS/MINUS zoom keys. A slice landing after 67A
    (56, 57, 69C) declares its default as `SDL_SCANCODE_*` (Slice 67
    addition folded into those slices).
  - `RuntimeInputBindings.keys: [action_count][2]c.SDL_Scancode`, with
    `SDL_SCANCODE_UNKNOWN` (0) as the empty slot.
- **Resolvers.** `actionForScancode(bindings, sc)` replaces `actionForKey` and
  reads `event.key.scancode` everywhere:
  - `actionPressForEvent`
  - `routeEventWithGamepad` (`input_router.zig:90`)
  - the test-path `InputState.handleEvent` / `FrameCommands.handleEvent`
- **Capture.** `RebindCaptureState` captures `event.key.scancode`.
  - Raw cancel is `scancode == SDL_SCANCODE_ESCAPE`.
  - Clear is `SDL_SCANCODE_BACKSPACE` / `SDL_SCANCODE_DELETE`.
  - The one-input-one-action invariant and its default-table test are
    unchanged in form.
- **Labels.** New `sdl.keyLabelForScancode(sc, buf: []u8) []const u8`
  (`src/platform/sdl.zig`):
  - `SDL_GetKeyName(SDL_GetKeyFromScancode(sc, SDL_KMOD_NONE, false))`, copied
    into `buf`.
  - An empty name falls back to `SDL_GetScancodeName(sc)`.
  - On AZERTY, physical W shows "Z".
  - Engine bumps `InputPrompts.epoch` on `SDL_EVENT_KEYMAP_CHANGED`, so
    prompts and Controls cells relabel after an OS layout switch. Labels are
    still computed only on change.
- **Settings schema.** `k_settings_format_version` += 1 over the live value
  when 67A lands (relative rule; v4 in the merged order: 54 v1, 44 v2 list
  form, 60 v3 `video.zoom_index`). Every earlier section, including 60's
  `zoom_index`, passes through unchanged.
  - Keyboard entries persist as `.{ .action = .move_up, .device = .keyboard,
    .slot = 0, .scancode = 26 }`. Scancodes are USB HID usage IDs and stable
    across SDL versions.
  - Gamepad entries are unchanged.
  - Load validation is 44's list, with `scancode = 0` in an occupied slot
    replacing `key = 0`.
- **Migration** (`settings_file.zig` stays pure):
  - The step this slice adds is two pure halves. `upgradeVNToVN+1(old)
    UpgradeResult` converts the file format and returns the old keyboard
    entries as a `PendingKeyMigration`; `migrateKeys(pending, key_to_scancode:
    KeyToScancode) KeyMigrationResult` converts them, with `KeyToScancode =
    *const fn (u32) u16`. The function pointer is a real runtime dependency
    (the OS keymap), not a test hook. Later upgrade steps (70B's v5) run on
    top of the first half; the keys stay parked until the second half runs.
  - The production adapter is `sdl.scancodeFromKeycode` →
    `SDL_GetScancodeFromKey(key, null)`.
  - **Keymap-ready timing.** `SDL_Init(VIDEO)` does not guarantee the real
    keymap. Until a backend installs one, SDL answers from its default (US)
    keymap. On Wayland the seat keymap arrives asynchronously:
    `Wayland_SeatSetKeymap` runs from the `wl_keyboard.keymap` handler and
    again from `keyboard_handle_enter` (SDL 3.4.18
    `src/video/wayland/SDL_waylandevents.c:398-408`, `:1755`, `:2069`).
    Migrating at load would bake a US mapping in permanently on an AZERTY
    Wayland seat. So the step is split:
    - `SettingsStore.load` (Engine.init step 5) runs every other upgrade
      step, applies the non-input sections, and parks the old keyboard
      entries in `pending_key_migration: ?PendingKeyMigration` (fixed
      `[action_count][2]u32` keycodes plus slot flags; no allocation). While
      it is set, `RuntimeInputBindings.keys` holds the scancode defaults.
    - The migration runs on the first delivered `SDL_EVENT_WINDOW_FOCUS_GAINED`
      or `SDL_EVENT_KEYMAP_CHANGED`, whichever comes first
      (`Engine.handleEvents` → `settings.completeKeyMigration(sdl
      .scancodeFromKeycode)`, which runs `migrateKeys` and the validation
      below). Keyboard events require keyboard focus, and
      every backend has installed its keymap before it delivers focus
      (Wayland sets it inside the enter handler before the app can poll the
      focus event; X11, Windows, and Cocoa build it synchronously at video
      init), so no key press is ever resolved against the defaults.
    - The file write waits for completion: `save_requested` set by the
      upgrade (migration freeze below) is held while `pending_key_migration` is
      set. A session that never gains focus (headless, or closed first)
      never writes, so the old file survives and the next launch migrates
      again. Settings changed by mouse before focus are applied and written
      together with the migrated bindings.
  - Each old `.key` converts through the current keymap. A keycode bound on
    AZERTY as "z" becomes physical W, which preserves what the user saw.
  - `SDL_SCANCODE_UNKNOWN` results are dropped; that slot keeps its default
    through the list-form fill.
  - The migrated table then runs the standard binding validation. If it fails
    (a default now collides with a migrated key):
    - **only** the `input` section resets to defaults, with one `warn`
      ("keyboard bindings reset during scancode migration")
    - audio, video, accessibility, and other sections are kept
    - this replaces 54's whole-file rejection for this specific failure
- **Migration freeze (amends 54's load path).** A load that ran any
  `upgradeVNToVN+1` step sets `save_requested = true`. The first
  `applyPendingSettings` after any deferred step has completed (today only
  this slice's keymap-ready migration) writes the latest version. Migration
  runs once, and a later OS layout change cannot re-migrate the old file
  differently.
- **Documented behavior change.** On non-QWERTY layouts, defaults bind
  physical positions (AZERTY gets ZQSD labels for WASD positions). On QWERTY,
  behavior is unchanged.

**Fixed budgets** (independent of content and world size):

| Constant | Value |
| --- | --- |
| `k_wheel_rows_per_tick` | 3 |
| `k_tooltip_delay_ns` | 600 ms |
| `k_tooltip_offset` | {12, 18} logical px |
| tooltip hint cap | 128 bytes (build-time error) |
| `k_menu_repeat_delay_ns` / `k_menu_repeat_interval_ns` | 400 ms / 100 ms |
| synthesized menu presses | ≤ 1 stick press + ≤ 1 repeat per frame |
| `k_menu_stick_press_raw` / `k_menu_stick_release_raw` | 16384 / 11469 |
| hit test | O(64) per pointer event |

**Errors.**
- `UiBuildError` gains `UiTooltipTooLong`. (It survives Slice 67E, which
  changes `hint` to a `?StringId` and measures the resolved English text.)
- There are no new runtime error sets. The pointer, repeat, and tooltip paths
  are infallible.
- Migration outcomes are logged, never returned.

**Diagnostics.**
- `app` scope:
  - `debug` once per migration with the count of converted / dropped keys
    and the triggering event (focus or keymap change)
  - `warn` on input-section reset
- Comptime-gated `runtime_perf_log` counters (Debug/ReleaseSafe only):
  `ui_pointer_events`, `ui_menu_repeats`.
- No per-event logging.

### Checklist

- [ ] `input.zig`: `InputDevice.pointer`, `PointerEvent`, `PointerWheel`,
      `promptDevice`. Tests:
      - prompt epoch does not bump on keyboard↔pointer alternation
      - it does bump on pointer→gamepad
- [ ] `renderer.zig` `windowPointToLogical` facade. Tests on a CPU-only
      renderer (`renderer.zig` fixture pattern):
      - `null` before any presentation
      - centre-point and letterbox-bar mapping after a seeded presentation
- [ ] `Engine.handleEvents`:
      - resolves `pointer`, `timestamp_ns`, and `device = .pointer`
      - `.leave` on mouse-leave / focus-lost
      - cursor show/hide on device change (`sdl.setCursorVisible`)

      Pure resolver `pointerEventFor(event, mapper) ?PointerEvent` in
      `input.zig`, tested with synthetic SDL events:
      - motion inside and outside the viewport
      - left down in the bars → `null`
      - up outside → `.primary_up = null`
      - right button → `null`
      - wheel flipped negates
      - `integer_y == 0` → `null`
- [ ] `ui/pointer.zig` `hitTest`. Tests:
      - topmost-wins for overlapping siblings
      - invisible skipped
      - scroll child outside the clip rect not hit
      - 64-widget worst case
- [ ] `UiScreen.handleEvent` / `handlePointer` / `rectOf` / `setTooltip`.
      Tests with a synthetic `W` screen:
      - hover focuses only on motion; a press then moves focus and a
        stationary cursor does not steal it back
      - hover over a label keeps focus
      - button down+up activates; down on A and up on B does nothing
      - slider down/drag/up emits `value_changed` only on change, clamped and
        quantized
      - toggle flip and choice cycle by click
      - wheel scrolls the scroll ancestor and clamps both ends
      - wheel over a slider never changes its value
      - consumption rule, including the HUD never consuming
      - `.leave` clears press/drag/hover
- [ ] `list` (44) pointer cells and wheel rows, with tests. `RebindCaptureState`
      amendments, with tests:
      - a click cancels capture and is consumed
      - motion and wheel are consumed
      - `press.repeat == true` is rejected for key and synthesized pad events
      - a synthesized left-stick fresh press (raw `GAMEPAD_AXIS_MOTION` on
        `LEFTX`, `repeat = false`) is consumed and not captured, while a
        trigger axis crossing and a `GAMEPAD_BUTTON_DOWN` are captured
- [ ] `ui/tooltip.zig` + draw, with tests:
      - shows exactly at 600 ms using `frame_start_ns`
      - hidden by a press, a click, and a move to another widget
      - clamped inside the canvas at each corner
      - `setText` only on candidate change (fake label backend call count)
      - `UiTooltipTooLong` at `build()`
- [ ] Demo HUD tooltips on depth gauge and portrait. `GameDemoState.handleEvent`
      forwards and returns `false`. `RenderContext.frame_start_ns`.
- [ ] `menu_repeat.zig` `MenuRepeat`. Pure tests with synthetic ns:
      - first repeat at +400 ms, then every 100 ms
      - one fire per `due` call with no burst after a 2 s gap
      - button up disarms
      - another button's up does not
      - stick press/release hysteresis
      - a direction change gives a fresh press
      - the stick is ignored when the policy allows `.gameplay`
      - `cancel()`
- [ ] Engine wiring:
      - arm/disarm from delivered events
      - synthetic dispatch through `StateStack.handleEvent` with `repeat =
        true`, never routed
      - `TransitionApplyResult.stack_changed` → `cancel`
      - disconnect and focus-lost disarm

      Test: a modal test state receives `menu_down` repeats from a held D-pad
      and none after a push applies.
- [ ] Scancode bindings:
      - `KeyBinding.scancode`, scancode defaults, `actionForScancode`
      - router/press/capture on `event.key.scancode`
      - `sdl.keyLabelForScancode`, `KEYMAP_CHANGED` epoch bump

      Update every keyboard test helper (`input.zig:337-391`,
      `input_router.zig:199-213`) to set `.scancode`. Tests:
      - each default resolves by scancode
      - an event whose `.key` disagrees with its `.scancode` resolves by
        scancode (the AZERTY case)
- [ ] Settings schema bump + migration step + migration freeze. `settings_file.zig`
      tests use a local table-driven `KeyToScancode`:
      - a previous-version file migrates `.key = 'a'` to `.scancode = 4`
        (audio/video kept)
      - an unmappable key falls back to that slot's default
      - a migration collision resets only `input`, with the warn path
      - the new version round-trips
      - `scancode = 0` in an occupied slot is rejected
      - a load that upgraded sets `save_requested`
      - an upgraded load parks the keyboard entries, keeps scancode
        defaults, and holds the write; `completeKeyMigration` with the
        table-driven `KeyToScancode` converts them and releases the write
      - a store whose migration never completes performs no write (the old
        file bytes are unchanged in a `tmpDir`)
      - Engine-level: the first `WINDOW_FOCUS_GAINED` or `KEYMAP_CHANGED`
        completes the migration exactly once; a second event does nothing
- [ ] `FailingAllocator` proofs:
      - (a) warmed screen: motion + down + up + wheel + render into a reserved
        CPU-only renderer, with labels on the fake backend
      - (b) tooltip show → render → hide → render
      - (c) `MenuRepeat.due` + synthetic dispatch through a `StateStack` whose
        allocator is failing
      - (d) `actionForScancode` / `actionPressForEvent`
      - (e) `completeKeyMigration` on a loaded store with a parked
        `PendingKeyMigration` (the fixed-size park and the conversion
        allocate nothing; the held file write is not part of this proof)
- [ ] Bench group `ui-pointer-hit` in `src/benchmarks/ui.zig` (registered in
      `runner.zig`; one group per workload; serial-direct only). Workload: a
      64-widget synthetic screen, item counts 1,024 / 4,096 pointer events
      (motion-heavy mix with clicks and wheel) through
      `UiScreen.handlePointer`.
- [ ] Docs:
      - `docs/state-stack-and-input.md`: new `## Pointer`, `## Menu
        repeat`, `## Scancode bindings` (layout behavior, migration, migration
        freeze); update `## Input Model` default-bindings wording to physical
        keys
      - `docs/architecture.md`: input-flow sentence covers pointer and
        synthesized repeats
      - `src/tests.zig` registers the new modules
- [ ] Add the settings migration-freeze rule to `.claude/rules/input-state.md`
      when this lands.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build bench -- --group ui-pointer-hit` runs; the baseline is
      recorded in Status.
- [ ] Manual (display):
      - every 53B/54/44/46 menu is fully usable by mouse alone (hover, click,
        slider drag, wheel in the settings scroll and Controls list)
      - the HUD tooltip appears after about 0.6 s of hover
      - letterbox clicks do nothing
      - HiDPI and a ~1.5× fit window map clicks to the right widget
- [ ] Manual (hardware pad):
      - held D-pad and the left stick scroll menus at 400/100 ms
      - holding through Confirm does not scroll the next screen
      - the cursor hides on pad use and reappears on mouse motion
- [ ] Manual (AZERTY layout, on X11 and on a Wayland compositor): WASD
      defaults act on physical WASD positions; the Controls screen shows
      "Z/Q/S/D"; a previous-version `settings.zon` with a keycode bound as
      "z" migrates once to physical W (not US Z) and its file is rewritten at
      the new version.
- [ ] Review check: `src/game/ui/` reads only `EventContext` fields, with no
      SDL types beyond 53B's existing allowance and no per-event allocation.

### VoidLight reference

- **Port:**
  - `src/managers/UIManager.cpp:1902-2094` `handleInput`:
    - topmost-first hit order
    - modal swallow of input below
    - press-then-release click on the same component
    - slider value from relative x
    - gamepad selection beats a stale mouse hover (`:2066-2092`), here
      expressed as "focus changes only on motion"
  - `:2095-2108` tooltip candidate timer.
  - `include/managers/UIConstants.hpp:29-31`: tooltip padding and mouse
    offset, adapted to 6 and {12, 18}.
  - Physical-key intent: VL reads `SDL_SCANCODE_*` throughout
    (`src/gameStates/MainMenuState.cpp:252-258`).
- **Do not port:**
  - polling mouse state per frame (`m_mousePressed` diffing); ZL is
    event-driven
  - the per-frame sorted component walk and `m_hoveredComponents` vectors
  - deferred `std::function` hover/focus/click callbacks
  - string component IDs
  - the 1.0 s `DEFAULT_TOOLTIP_DELAY` (`UIConstants.hpp:129`; ZL uses 600 ms)
  - VL's lack of gamepad repeat

---

