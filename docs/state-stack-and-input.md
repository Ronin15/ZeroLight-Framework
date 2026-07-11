# State Stack And Input

## State Shape

Create a state struct with the methods used by `src/app/state.zig`:

```zig
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const c = @import("../platform/sdl.zig").c;

pub const MyState = struct {
    pub fn init() MyState {
        return .{};
    }

    pub fn deinit(self: *MyState) void {
        _ = self;
    }

    pub fn handleEvent(
        self: *MyState,
        event: *const c.SDL_Event,
        transitions: *StateTransitions,
    ) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *MyState, context: UpdateContext) !void {
        _ = self;
        _ = context.input;
        _ = context.delta_seconds;
        _ = context.transitions;
        _ = context.thread_system;
    }

    pub fn render(self: *MyState, context: RenderContext) !void {
        _ = self;
        _ = context.renderer;
        _ = context.runtime_assets;
        _ = context.text_service;
        _ = context.interpolation_alpha;
        _ = context.thread_system;
    }

    pub fn onPause(self: *MyState) void {
        _ = self;
    }

    pub fn onResume(self: *MyState) void {
        _ = self;
    }
};
```

Return `true` from `handleEvent` when the state consumes an event.

`onPause` is required; `onResume` is optional (`src/app/state.zig`'s adapter
calls it only when `@hasDecl(T, "onResume")`). Only gameplay-owning states
like `GameDemoState` implement `onResume`; pure UI states typically implement
`onPause` alone.

`UpdateContext` carries `asset_store` (an `assets.AssetStore` handle) so a state
can load content catalogs at init from the traversal-safe asset root —
`GameDemoState` uses it to load the AI archetype catalog
(`assets/ai/archetypes.json`). `RenderContext` carries `debug_overlay_visible`,
mirrored from the Engine-owned debug overlay's F2 / gamepad-BACK toggle; a state
reads it to gate render-only debug draws (e.g. the AI introspection overlay)
without owning input or a second toggle.

## Transitions

Use `StateTransitions` from inside a state when a change should happen after the
current dispatch finishes:

```zig
try context.transitions.replaceGameplay(MainMenuState, MainMenuState.init());
try context.transitions.replaceOwnedGameplay(owned_state);
try context.transitions.pushModal(PauseMenuState, PauseMenuState.init());
try context.transitions.pushOverlay(HudState, HudState.init());
try context.transitions.replaceOwnedState(loading_state, state_policy.opaque_screen);
try context.transitions.quit();
```

Use `replaceOwnedState` / `replaceOwnedGameplay` only when a state has to be
allocated before the transition can be enqueued, such as a fallible gameplay
launch from a menu or a runtime-asset-backed loading screen. Ownership transfers to `StateTransitions`; if enqueueing
fails, the transition API destroys the owned state.

Use `StateStack` directly only in app/bootstrap code, such as replacing the
startup state in `src/app/engine.zig`.

`StateStack` owns state allocation and destruction. It calls `deinit` when
states are removed or replaced, and destroys remaining states from top to bottom
when the stack shuts down.

Menu activation should not directly construct gameplay states that require
runtime catalogs. `MainMenuState` installs an opaque `LoadingState`; that state
receives `UpdateContext.runtime_assets` and `UpdateContext.asset_store`, builds
the `GameDemoState` world from Engine-owned runtime assets (and loads the AI
archetype catalog through the asset store), and replaces itself with owned
gameplay.

## Policies

- `replaceGameplay` installs a normal gameplay/screen state (carries `StatePolicy.gameplay = true`).
- `pushModal` blocks updates and events below it while still rendering lower states.
- `pushOverlay` allows updates, events, and rendering below it.
- `pushOpaque` blocks rendering below it for full-screen replacement views.

`StatePolicy` carries a `gameplay: bool` flag (defaults false; only `state_policy.gameplay` sets it true).
This flag is the source of truth for "active game state" (states installed via `replaceGameplay` / `replaceOwnedGameplay`).
It is independent of the routing / update / render / events policy bits.

Pause (user via P or `resumeGame` reversal, and window/frame-policy via `should_pause_gameplay`) only enters
when a gameplay state is active (`StateStack.isGameplayActive()`). `PauseController` (and light guards in `Engine`)
gate entry so the `PauseState` overlay + audio duck + time reset is never applied over menus or other non-gameplay
states. `pauseActive` / `resumeActive` (called by the controller) walk to the unique recipient entry carrying the
`gameplay` flag and deliver `onPause` / `onResume` to it. This ensures the real owner (e.g. `GameDemoState`)
receives the interp sync call even when a pass-through overlay (or the PauseState modal itself after push) is
the literal top of the stack. Menus and pure UI states implement `onPause` as a no-op and never receive it from
the pause flow.

Policies also control named-action routing:

- Gameplay states allow held gameplay input, app commands, and debug commands.
- Modal overlays block held gameplay input while keeping app and debug commands
  available.
- Pass-through overlays allow gameplay, UI, app, and debug action contexts unless
  a modal or opaque state in the active event path blocks held gameplay input.
- Opaque screens block gameplay input and keep app and debug commands available.

The top state controls command availability. Held gameplay input is also gated
by modal and opaque states in the active event path, so pass-through overlays do
not tunnel movement through a modal state beneath them.

`.pause` / `.resumeGame` remain routable under modal and opaque policies
(intentionally, to support P/Enter/Space resume when the pause overlay is the
top modal). Menu states consume their handled raw events, so those events do not
also produce global frame commands. The gameplay flag gate in the controller
makes any non-gameplay pause attempt a safe no-op.

## Input Model

Keyboard input maps to named `Action` values in `src/app/input.zig`.

Held gameplay input:

- `moveLeft`
- `moveRight`
- `moveUp`
- `moveDown`
- `digHole`
- `digRamp`
- `digDown`

One-frame commands:

- `pause`
- `resumeGame`
- `quit`
- `toggleDebugOverlay`
- `menuUp`
- `menuDown`
- `menuLeft`
- `menuRight`

`pause`, `resumeGame`, and `quit` are app commands. `toggleDebugOverlay` is a
debug command. The four `menu*` actions are routed under the `.ui` context (see
`InputRoutingPolicy.modalUi` / `opaqueScreen`); they are one-frame commands captured
by `FrameCommands` (not held movement).

Default bindings are:

- WASD for movement
- E/Q/F for dig hole/ramp/down
- Arrow keys for menu navigation (up/down/left/right)
- P for pause or resume
- Enter or Space for resume (also used as confirm/activate inside menus)
- Escape for quit (also used as back/cancel inside modal menus such as settings)
- F2 for the debug overlay

Gameplay code should read movement through `InputState`, usually from the
`UpdateContext`. App-level commands should stay in `FrameCommands` and engine
coordination code. `State.handleEvent` still receives raw SDL events according
to `events_below`; input routing only decides whether named actions mutate
`InputState` or `FrameCommands`.

Menu states (e.g. main menu as an opaque screen, settings as a modal overlay)
receive raw key-down or gamepad-button-down events in `handleEvent`, translate
them through `input.actionForPressEvent(...)` (resolves either shape to a
named `Action` in one call), and act on named `Action` values for confirm,
back, and navigation. Settings-style modal states use
`context.transitions.pop()`; quit rows use `quit()`. Main menu Start installs
an opaque owned `LoadingState` with `replaceOwnedState(...)`, and
`LoadingState` later queues `replaceOwnedGameplay(...)` after constructing
gameplay from `UpdateContext.runtime_assets`. When a state returns `true` from
`handleEvent`, `Engine` does not route that same event into global
`FrameCommands`, so menu Enter/Escape handling does not also resume/pause/quit
through the app command path.

## Gamepad

`Engine` requests `SDL_INIT_GAMEPAD` unconditionally alongside video (and audio
when enabled) — `SDL_INIT_GAMEPAD` implies `SDL_INIT_JOYSTICK`, so no separate
flag is needed. `src/app/gamepad.zig`'s `GamepadManager` owns device lifecycle:
at most one `*SDL_Gamepad` handle is open at a time (single active gamepad,
matching this framework's single-player scope; no simultaneous
multi-controller merging).

Lifecycle policy:

- **First-connected-wins**: `openInitial()` (called once from `Engine.init`
  after SDL init) adopts the first already-connected device, if any.
  `SDL_EVENT_GAMEPAD_ADDED` only adopts a new device when nothing is currently
  active.
- **Hot-plug disconnect**: `SDL_EVENT_GAMEPAD_REMOVED` only reacts when the
  removed device is the currently active one. On disconnect, the manager
  closes it and immediately tries to open a fallback from any other
  already-connected device (first-available-wins); if none is available, input
  falls back to keyboard only. Either way, `Engine.handleEvents` calls
  `InputState.releaseGamepadInput()` on disconnect so movement, held dig
  actions, and stick deflection cannot get stuck mid-press across the unplug.
- Plugging in a second controller while one is already active does not steal
  input from the first — it is simply ignored until the active device
  disconnects.

The three adoption/fallback decisions
(`shouldAdopt`/`isActiveDevice`/`pickFallback`) are pure functions unit-tested
against synthetic `SDL_JoystickID` values; the `SDL_OpenGamepad`/
`SDL_GetGamepads` glue itself is not unit-testable without real or virtual
hardware (same posture as the display-gated `gpu-smoke` probe).

### Default gamepad bindings

Gamepad buttons reuse the exact same `Action` enum and `InputRoutingPolicy`
machinery as keyboard — there is no separate gamepad routing surface.
`input_router.zig` resolves `SDL_EVENT_GAMEPAD_BUTTON_DOWN`/`_UP` through
`actionForGamepadButton` and routes it through the same `routeAction` helper
keyboard events use, so policy gating, held-vs-one-frame classification, and
repeat handling (gamepad buttons never repeat — SDL does not synthesize repeat
events for them) all behave identically to keyboard. This slice ships default
bindings only; there is no rebind UI yet.

`default_gamepad_bindings` in `src/app/input.zig`:

- D-Pad Up -> `menuUp`
- D-Pad Down -> `menuDown`
- D-Pad Left -> `menuLeft`
- D-Pad Right -> `menuRight`
- South (A / Cross) -> `resumeGame`
- East (B / Circle) -> `quit`
- Start -> `pause`
- West (X / Square) -> `digHole`
- North (Y / Triangle) -> `digRamp`
- Right Shoulder -> `digDown`
- Back -> `toggleDebugOverlay`

### Analog left-stick movement

The left stick drives true continuous, variable-speed movement — not a
digital d-pad-style boolean synthesis. `input_router.zig` gates
`SDL_EVENT_GAMEPAD_AXIS_MOTION` on `InputRoutingPolicy.allowsContext(.gameplay)`
(all move actions are `.gameplay`, so no per-axis `Action` mapping is needed)
and forwards only `SDL_GAMEPAD_AXIS_LEFTX`/`_LEFTY` to
`InputState.handleGamepadAxis`; other axes (right stick, triggers) are a
no-op.

Raw axis values feed a **scaled radial deadzone**
(`gamepad_stick_deadzone = 0.24`, roughly SDL's own documented center noise
band): a stick magnitude at or below the deadzone reports zero, and the
remaining `[deadzone, 1]` range is rescaled to `[0, 1]` so a corner-pushed
stick still reports magnitude ~=1 instead of the raw unscaled diagonal value.

`InputState.movementVector()` adds the deadzoned stick vector to the keyboard
digital direction, then clamps each axis independently to `[-1, 1]`. The
combined vector's *length* is intentionally not clamped to 1: keyboard-only
diagonal movement has always been exactly sqrt(2) in this framework (unchanged
by this slice — normalizing it now would be an unrequested gameplay-feel
change), and gamepad-only diagonal is already <=1 by construction from the
deadzone normalization above. The only new edge case — both devices pushing
the same axis at once — is capped by the per-axis clamp at the same sqrt(2)
ceiling keyboard-only input already produced, so nothing regresses.
`InputState.releaseMovement()` (and the pause-controller call sites that
already invoke it) also zero the raw stick fields, so a paused/blocked
gameplay context cannot leave stale deflection to snap back in on resume.
