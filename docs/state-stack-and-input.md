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

## Transitions

Use `StateTransitions` from inside a state when a change should happen after the
current dispatch finishes:

```zig
try context.transitions.replaceGameplay(MainMenuState, MainMenuState.init());
try context.transitions.replaceOwnedGameplay(owned_state);
try context.transitions.pushModal(PauseMenuState, PauseMenuState.init());
try context.transitions.pushOverlay(HudState, HudState.init());
try context.transitions.pushOpaque(LoadingState, LoadingState.init());
try context.transitions.quit();
```

Use `replaceOwnedState` / `replaceOwnedGameplay` only when a state has to be
allocated before the transition can be enqueued, such as a fallible gameplay
launch from a menu. Ownership transfers to `StateTransitions`; if enqueueing
fails, the transition API destroys the owned state.

Use `StateStack` directly only in app/bootstrap code, such as replacing the
startup state in `src/app/engine.zig`.

`StateStack` owns state allocation and destruction. It calls `deinit` when
states are removed or replaced, and destroys remaining states from top to bottom
when the stack shuts down.

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
receive raw key-down events in `handleEvent`, translate them through
`input.actionForKey(...)`, and act on named `Action` values for confirm, back,
and navigation. They use `context.transitions.pop()` (added alongside Slice 16)
or `quit()` / `replaceOwnedGameplay(...)`. When a state returns `true` from
`handleEvent`, `Engine` does not route that same event into global `FrameCommands`,
so menu Enter/Escape handling does not also resume/pause/quit through the app
command path.
