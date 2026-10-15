## Slice 16: Main Menu and Settings Menu

Goal: provide a root main menu as the default startup state and a reachable settings menu for basic configurable options (initially live audio bus/master gains) so the app no longer boots directly into gameplay. Menus use the existing state stack (opaque + modal policies), input routing (new menu actions routed under the `.ui` context), text service for labels, renderer logical-space drawing, and audio command buffer for fixed-step gain changes.

Current foundation:

- `StateStack` + `StateTransitions` (replaceGameplay, replaceOwnedGameplay, pushModal, pop support added in this slice) and the four policies (gameplay / modal_overlay / pass_through_overlay / opaque_screen).
- `InputState` / `FrameCommands` + `input_router` with explicit `.ui` context and `modalUi`/`opaqueScreen` policies that already block gameplay movement while allowing app/debug/ui commands. Consumed state events suppress fallback routing into global frame commands.
- `TextService` cached text drawing/preparation (Slice 5) and explicit
  `Renderer.submitOrdered*` logical-space calls for already ordered UI helpers.
- `PauseState` provides the concrete drawing, stack-aware
  `UiDepth`/`RenderOrder.uiInStack(...)`, color, text-measurement, and
  centered-panel precedent.
- `AudioCommandBuffer.setMasterGain` / `setBusGain` + `AudioBus` (Slice 15) for live settings feedback without owning mixer resources. MainMenuState owns the runtime audio-setting values so they persist across settings reopen and into gameplay launch.
- `MainMenuState` launches `LoadingState`, which constructs `GameDemoState`
  from Engine-owned `RuntimeAssets` before replacing itself with gameplay.
- `bootstrapStartupState` in Engine with the explicit comment that a real MainMenuState was expected.
- Menus use `handleEvent` (raw SDL events, which reach top state for modal/opaque policies) and translate keys through `input.actionForKey(...)` before acting on named ui/app actions. `UpdateContext` carries input, audio for gain commands, runtime_assets for loading-state construction, transitions, and thread_system; `RenderContext` carries renderer + runtime_assets + optional text_service. This matches the actual `UpdateContext` definition (no one-frame commands field).
- All states follow the vtable shape with `init`/`deinit`/`update`/`render`/`handleEvent` and required `onPause`; `onResume` is optional.

Architecture notes:

- `StatePolicy.gameplay` is the source of truth for active gameplay; pause entry
  is gated by `StateStack.isGameplayActive()`.
- `pauseActive` / `resumeActive` target the gameplay-policy state, so overlays
  can sit on top without stealing gameplay pause notifications.
- Menu and settings states are non-gameplay UI states; pause attempts over them
  are inert.
- Settings are currently runtime menu state. Persistent settings file work
  should move pending adjustment persistence out of modal-local state so closing
  the settings menu cannot drop a not-yet-applied adjustment.

Checklist:

- [x] Add four menu navigation actions (`menuUp`/`menuDown`/`menuLeft`/`menuRight`) bound to arrow keys, classified as command actions, and routed to the `.ui` context. Update binding, routing, and action tests.
- [x] Extend `StateTransitions` and `StateStack` with `pop()` (request + apply + destroy) plus minimal tests so child menus can dismiss themselves cleanly.
- [x] Implement `MainMenuState` (src/game/main_menu_state.zig) as an opaque-screen root menu: 3 items, allocator storage for spawning GameDemo, selection + wrap, text-service-backed title+items with accent for selected, logical rect + text rendering, confirm via resumeGame action, quit action exits, transitions to gameplay or settings or app quit. Internal focused tests.
- [x] Implement `SettingsMenuState` (src/game/settings_menu_state.zig): 3 volume rows + Back, u8 0-10 state, menuLeft/menuRight records a pending adjustment for the selected volume, the next update queues set*Gain, labels render from current state, quit action or Back confirm does pop(), same visual style. Tests for clamping, emitted commands, pop, and command-failure consistency.
- [x] Update Engine bootstrap to create MainMenuState (opaque) at startup with logical size + allocator; keep GameDemo import for launch path. Update the old placeholder comment.
- [x] Register the two new game modules in src/tests.zig comptime block for `zig build test` coverage.
- [x] Add the full Slice 16 section (this text) to framework-implementation-slices.md following prior slice format, plus update Next Priority Tracks and the Suggested Order list.
- [x] Minor doc updates in state-stack-and-input.md (new actions in input model) and architecture.md (new states under game/, bootstrap note).
- [x] `zig build fmt`, `zig build test`, `zig build check`, `zig build verify` all pass.
- [x] Manual `zig build dev` smoke confirmed: arrow navigation + wrap, Enter starts demo, Esc quits from main, Settings reachable, Left/Right adjust volumes with audible result and label update, Back/Esc returns to main, gains persist into launched gameplay, F2 overlay works, no leaks on repeated transitions.

Acceptance checks:

- [x] App starts at a usable main menu (title + 3 keyboard-selectable items) instead of the demo.
- [x] Arrow keys change selection (wraps); Enter/Space activates; Esc quits from main menu.
- [x] "Start Game" replace-launches a fully functional GameDemoState (player input, systems, audio, pause overlay still work).
- [x] "Settings" pushes a modal settings view; Left/Right on volume rows records a pending gain change, the next update queues the gain command, labels update, and Esc or Back returns cleanly via pop.
- [x] Volume changes made in settings are respected when starting gameplay afterward.
- [x] Menu states store dirty non-owning `PreparedText` views, not generated
      text texture ownership; stable render frames draw prepared views directly
      and `TextService` owns the app-lifetime text cache.
- [x] Focused (no-window) tests cover action-mapped selection, wrap, transition requests (including pop), volume clamp + command emission, and command-failure consistency.
- [x] Updated routing tests prove menu actions are allowed exactly under ui/modal/opaque policies and blocked from pure gameplay routing.
- [x] `zig build verify` passes; docs updated in the canonical slices format.

Slice 16 lands the first real menu layer. The implementation stays deliberately small (no widget system, keyboard only, volumes as the single live setting) while covering the tested contract: state-driven navigation through named actions, consumed-event ui input routing, service-cached text + logical renderer drawing, fixed-step audio command effects from menus, clean pop + replace transitions, allocator hand-off for spawned gameplay, pause restricted to active gameplay, and complete tests + docs. Future menu work (controls, graphics stubs, in-game pause integration, persistence) can build directly on these states and the pop primitive.

