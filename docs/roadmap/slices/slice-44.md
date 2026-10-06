## Slice 44: Input Rebinding And Extended Gamepad Controls

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 43](slice-43.md), [Slice 53B](slice-53b.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** App/input-layer work. Depends on Slice 43 (landed;
HW residual), Slice 53B (widgets, `EventContext`), and Slice 54
(`SettingsStore` persistence). Independent of the AI/render tracks.

Goal: fill the controls Slice 43 deliberately deferred — a rebind capture UI
(defaults are no longer the only option) and the right-stick / trigger axes it
left as no-ops — without recompiling to change a binding and without breaking
the device-agnostic `Action` contract keyboard and gamepad already share.
Custom bindings persist across launches in Slice 54's `settings.zon`, and every
prompt and binding cell shows the active device's own key or button names
(Xbox / PlayStation / Nintendo / keyboard).

### Current foundation (do not rebuild)

- `src/app/input.zig`'s `default_key_bindings` / `default_gamepad_bindings` are
  compile-time `pub const` tables; `actionForKey` / `actionForGamepadButton` /
  `actionForPressEvent` iterate them. A rebind UI needs a **runtime-mutable**
  table these resolvers read instead of the const arrays directly.
- `src/app/input_router.zig`'s `routeAction` + `SDL_EVENT_GAMEPAD_AXIS_MOTION`
  case forward only `SDL_GAMEPAD_AXIS_LEFTX`/`_LEFTY`; right stick and triggers
  arrive but are dropped.
- Slice 54's Engine-owned `SettingsStore` (versioned ZON, `upgradeVNToVN+1`
  chain, typed setters, `requestSave`) is where bindings live and persist.
- Slice 53B's `EventContext.press` is resolved once per event by `Engine`
  through `input.actionPressForEvent`, which is the single place to switch to
  runtime bindings. No state calls a binding resolver directly.
- `src/app/gamepad.zig:69-83` `openDevice` already queries
  `SDL_GetGamepadType` when it adopts a pad (debug log), so the type is known
  at adoption.
- `docs/state-stack-and-input.md:280` still says "there is no rebind UI yet".

### Architecture notes

- **`RuntimeInputBindings`** (`src/app/input.zig`):
  - **Layout:** `keys: [action_count][k_key_slots_per_action = 2]c.SDL_Keycode`
    (`SDLK_UNKNOWN` = empty) and `pad: [action_count][k_pad_slots_per_action =
    1]PadInput`.
  - **`PadInput`:** `enum(u8) { none, south, east, west, north, back, guide,
    start, left_stick, right_stick, left_shoulder, right_shoulder, dpad_up,
    dpad_down, dpad_left, dpad_right, left_trigger, right_trigger }`. These
    give readable ZON literals. Triggers act digitally, firing on an
    upward crossing of `k_trigger_press_threshold: i16 = 16384`.
  - **Defaults:** `defaults()` copies `default_key_bindings` /
    `default_gamepad_bindings`; the const tables stay the reset source.
  - **Storage:** the table lives at `RuntimeSettings.input`, owned by
    `SettingsStore`.
  - **Resolution:** `actionForKey`/`actionForPadInput` scan fixed tables (32
    + 16 entries — the same O(n) as today, with no hashing).
  - **Invariant:** an input maps to at most one action globally. Today's
    first-match behavior becomes an explicit invariant, enforced on edit and
    on load.
  - **Wiring:** Engine passes `&settings.current().input` to
    `actionPressForEvent` and `routeEventWithGamepad`. The test-only-used
    `InputState.handleEvent`/`FrameCommands.handleEvent` take the table too.
  - `toggle_debug_overlay` is not rebindable (dev tool; F2 / Back stay fixed):
    `isRebindable(action)`.
  - **Later actions.** The table is `[action_count]`, so an `Action` appended
    by a later slice (56 `attack`, 57 `use_item`, 60 `camera_zoom_in` /
    `camera_zoom_out`) becomes a Controls row, rebindable and persisted, with
    no change here and no schema bump: the appending slice adds its defaults
    to the const tables, and the list form keeps defaults for entries a file
    omits. A later slice may ship an empty pad slot; Slice 60 does so for
    zoom, and players bind a gamepad zoom button on this screen. Slice 70B
    sets the R3/L3 defaults and moves 56/57 to the triggers (pad defaults
    and the explicit-beats-default-fill loader rule — `.none` /
    `SDL_SCANCODE_UNKNOWN` — owned by Slice 70B, bind every later settings
    step). A test
    asserts the default tables satisfy the one-action-per-input invariant, so
    a colliding default added later fails `zig build test`.
- **Controls screen.** `ControlsMenuState` (modal), opened from Slice 54's
  Settings screen through a new **Controls** button.
  - It holds one **`list`** widget, which lands in this slice as its first
    consumer:
    - rows ≤ `k_max_list_rows = 64`, columns ≤ `k_max_list_columns = 3`
    - row text is held in fixed per-list buffers
    - labels exist only for visible rows
    - focus moves over (row, column) and auto-scrolls
    - the new `UiEvent` arm is `list_activated { widget, row: u16, column: u8
      }`
  - Rows are the rebindable actions in `Action` order. Columns: action name |
    key binding (slots 0/1 joined) | pad binding.
  - Also on the screen: **Reset Controls** (confirm), **Back**, and a prompt
    footer.
- **Capture.** Activating a binding cell pushes `RebindCaptureState` (modal)
  with `{ action, category: enum { keyboard, gamepad }, slot }`.
  - **Swallows everything:** while open it consumes every key-down,
    gamepad-button-down, and trigger axis event (returns `true`), so nothing
    reaches `FrameCommands`. Otherwise Esc would quit and Start would pause.
  - **Category filter:** a keyboard capture ignores pad input, and the
    reverse.
  - **Fresh presses only:**
    - key events with `repeat = true` are ignored
    - the press that opened the capture is never captured: its DOWN was
      consumed before the push applied, its repeats are ignored, and UP events
      are ignored
  - **Cancel and clear:**
    - Raw `SDLK_ESCAPE` cancels, regardless of what `quit` is bound to, so a
      rebound quit cannot trap the user. Escape itself therefore comes back
      only through Reset.
    - Backspace/Delete clears the targeted slot.
    - `k_rebind_capture_timeout_steps = 600` (10 s at 60 Hz) auto-cancels,
      for gamepad users without a keyboard.
  - **Done latch:** after a commit or cancel, the state ignores the rest of
    the event batch until its `pop` applies.
- **Conflict and protection policy.**
  - **Conflicts:** if the captured input is already bound to another action,
    reject it. Nothing changes, capture stays open, and the footer says "<input>
    is already bound to <Action>". No silent shadowing; no auto-swap in v1.
  - **Protected actions:** `menu_up/down/left/right`, `resume_game`, `quit`,
    and `pause` must keep at least one binding per category. A clear is
    refused if it would break that; a replace always keeps one.
  - **Commit path:** `SettingsStore.setBinding(action, category, slot, input)
    !void` validates, marks dirty, and the caller calls `requestSave()`.
    `resetBindings()` restores the defaults.
- Add right-stick and trigger `Action` bindings with new axis cases in
  `input_router.zig`, gated by the same `InputRoutingPolicy` as the left stick.
  Right-stick semantics (e.g. camera/aim) stay a thin mapping — no new gameplay
  contract.
- **Persistence goes through Slice 54's settings file, never saves.** Slice 46
  excludes settings.
  - **Schema bump:** bump `k_settings_format_version` by one (v2 if 44 is the
    first bump; Slice 60's zoom setting also bumps it, in whichever order
    they land). The new version adds `.input = .{
    .bindings = .{ .{ .action = .move_left, .device = .keyboard, .slot = 0,
    .key = 97 }, .{ .action = .pause, .device = .gamepad, .slot = 0, .pad =
    .start }, … } }`.
  - **List form:** missing entries keep their defaults; an unknown `action` or
    `pad` literal rejects the whole file (Slice 54's rejection path).
  - **Upgrade:** the `upgradeVNToVN+1` step this slice adds keeps the previous
    version's audio, video, and accessibility (and any other fields present)
    and fills in default bindings.
  - **Load-time validation rejects:**
    - a duplicate (action, device, slot)
    - a slot out of range
    - an input bound to two actions
    - `key = 0` in an occupied slot
    - a protected action with no binding left in a category
  - **Key encoding:** keys persist as numeric `SDL_Keycode`, because the
    resolver stays keycode-based. Slice 67A switches keys to scancodes with
    the next schema bump (v4 in the merged order) and a keymap-ready
    migration step.
- **Gamepad family.** `GamepadManager.family: GamepadFamily = .generic` with
  `GamepadFamily = enum { xbox, playstation, nintendo, generic }`.
  - Set when a pad is adopted, by the pure `familyForType(SDL_GamepadType)`:
    - `XBOX360` / `XBOXONE` → `xbox`
    - `PS3` / `PS4` / `PS5` → `playstation`
    - `NINTENDO_SWITCH_PRO` / `NINTENDO_SWITCH_JOYCON_*` → `nintendo`
    - anything else → `generic`
  - Reset to `generic` when no pad is open.
- **Button and key labels.** `GamepadManager.buttonLabel(PadInput)
  []const u8`.
  - **Face buttons:** `SDL_GetGamepadButtonLabel(active, button)` gives
    vendor-correct A/B/X/Y vs Cross/Circle/Square/Triangle, including Nintendo
    positions. With no pad, use
    `SDL_GetGamepadButtonLabelForType(SDL_GAMEPAD_TYPE_XBOXONE, …)`.
  - **Other buttons:** a static family table, with Start labeled "Start"
    everywhere (VL rule):

    | Button | Xbox / generic | PlayStation | Nintendo |
    | --- | --- | --- | --- |
    | shoulders | LB / RB | L1 / R1 | L / R |
    | triggers | LT / RT | L2 / R2 | ZL / ZR |
    | sticks | L-Stick / R-Stick | L3 / R3 | L-Stick / R-Stick |
    | back | Back | Share | - |

  - **Keys:** `SDL_GetKeyName`, copied into the widget text buffer.
  - **When it runs:** only on change, never per frame.
  - Labels are text in v1; there is no button-icon atlas.
- **Prompt context.**
  - Engine tracks `last_input_device: InputDevice = enum { keyboard, gamepad
    }`, updated from delivered key-down, pad button-down, and pad stick
    beyond the deadzone.
  - It exposes `EventContext.device` and `RenderContext.input_prompts =
    InputPrompts { device, family, epoch }`. `epoch` bumps on a binding
    change, a family change, or a device switch.
  - Screens rebuild hint text only when the epoch changes. 53B's static hint
    footers become binding- and device-aware:
    - keyboard: "Enter: Select  Esc: Back"
    - Xbox: "A: Select  B: Back"
    - PlayStation: "Cross: Select  Circle: Back"

### Checklist

- [ ] (added by Slice 67) `RebindCaptureState` rejects `press.repeat == true` for
      every event shape (67A synthesized pad repeats), and accepts fresh presses
      only from `KEY_DOWN`, `GAMEPAD_BUTTON_DOWN`, or a trigger-axis
      `GAMEPAD_AXIS_MOTION` (67A left-stick presses are consumed, never
      captured).
- [ ] `RuntimeInputBindings` runtime table + reset-to-defaults; `actionFor*`
      resolve against it; tests that a rebound action resolves to the new
      key/button and that reset restores defaults.
- [ ] `ControlsMenuState` + `list` widget + `RebindCaptureState`, with tests
      for each path using both keyboard and gamepad event shapes:
      - category filter
      - fresh-press and repeat rejection
      - raw-Escape cancel while `quit` is rebound
      - Backspace clear
      - timeout
      - done latch
      - conflict rejection message
      - protected-action guard
- [ ] Right-stick / trigger `Action` bindings + `input_router.zig` axis cases,
      policy-gated; tests mirroring the left-stick gating/no-op tests.
- [ ] Settings schema bump by one + the `upgradeVNToVN+1` step this slice
      adds + binding validation, with tests: a previous-version file upgrades
      and keeps audio/video; the new version round-trips; each rejection
      reason fails.
- [ ] Default-table invariant test: no input maps to two actions across
      `default_key_bindings` / `default_gamepad_bindings`.
- [ ] `familyForType` and label-table tests (pure). The SDL label glue stays
      thin and untested, like the gamepad open glue.
- [ ] `InputPrompts` epoch and last-device tracking, with tests.
- [ ] `FailingAllocator` proofs: binding resolution, capture event handling,
      and a warmed `list` render all allocate zero.
- [ ] Docs:
      - `docs/state-stack-and-input.md`: `## Gamepad` plus a new `##
        Rebinding` (runtime table, capture rules, conflict and protection
        policy, persistence through the settings schema version this slice
        adds, prompt labels); remove "no
        rebind UI yet" (`:280`)
      - `docs/architecture.md`: input bullets

### Acceptance checks

- [ ] A rebound action resolves at runtime with no recompile; right stick /
      triggers drive their bound actions.
- [ ] Keyboard-only and default-binding paths are byte-for-byte unchanged.
- [ ] Rebound bindings survive a restart (`settings.zon` at the version this
      slice adds). A previous-version file upgrades with audio and video
      preserved and default bindings.
- [ ] Escape cancels capture even when `quit` is rebound away from Escape.
- [ ] Manual with hardware: prompts and binding cells show Xbox, PlayStation,
      and Nintendo names for the connected pad, and keyboard names after
      keyboard use.
- [ ] `zig build verify` passes.

### VoidLight reference

- **Port:**
  - `include/managers/InputManager.hpp:114-149` — capture API, persistence,
    `describeBinding`, vendor enum.
  - `src/managers/InputManager.cpp:239-268` — swallow the capturing input so it
    does not re-fire confirm.
  - `:270-400` `captureRebind`:
    - category filter (`:276-283`)
    - ESC cancels in any category
    - replace only the same-category binding
    - 0.5 trigger threshold
  - `:925-1006` label policy: face buttons via `SDL_GetGamepadButtonLabel`,
    vendor table for the rest, trigger labels, the `SDL_GetGamepadType`
    mapping (`:992-1006`).
  - `src/gameStates/SettingsMenuState.cpp:322-325` — save bindings when
    settings are applied.
- **Do not port:**
  - polling prev-state arrays (ZL is event-driven)
  - the JSON key-string maps (`InputManager.cpp:625-700`; ZON enum parse
    instead)
  - mouse-button bindings
  - stick-direction digital bindings
  - the separate `res/input_bindings.json` in the install directory
  - the singleton

