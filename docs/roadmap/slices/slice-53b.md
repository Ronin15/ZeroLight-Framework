## Slice 53B: UI Widget Toolkit, Menu Migration, And HUD Primitives

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 53A. Mostly game/UI-layer work, plus
small app-layer contract changes (`EventContext`, resume request). Independent
of the AI / simulation / world-render tracks.

Goal: a data-oriented, allocation-free-after-warmup widget toolkit that every
future game uses for menus and HUDs:
- retained screens declared once with enum widget IDs, with no strings or
  callbacks
- anchor/stack layout in logical resolution
- keyboard and gamepad focus driven only by named `Action`s
- theme loaded from data
- clipped scroll containers

The existing main menu, settings menu (interim), pause screen, and loading
screen move onto it; `menu_view.zig` is deleted; a demo HUD proves the HUD
primitives.

### Current foundation

- `src/game/menu_view.zig:21-104` — the only "toolkit" today: wrap-around
  `changeSelection` (`:21-27`) and a fixed vertical `renderList` with
  hard-coded geometry.
- `src/game/main_menu_state.zig:26-202`, `src/game/settings_menu_state.zig:47-242`,
  `src/game/pause_state.zig:20-117` (non-interactive overlay; Esc/B quits the
  app via `FrameCommands`), `src/game/loading_state.zig:47-221`.
- `src/app/state.zig:89-101` — `VTable.handle_event(*anyopaque, *const
  SDL_Event, *StateTransitions)`. `:480-489` `StateStack.handleEvent`.
  `:514-533` `render` assigns `ui_stack_order` per rendered state. `:58-60`
  `TransitionApplyResult { quit_requested }`. `:195-202` `Request` union.
  `:457-466` `pauseRecipient` walk.
- `src/app/input.zig:219-225` — `actionForPressEvent` (non-repeat key-down +
  gamepad button-down), called by every menu.
  `src/app/input_router.zig:163-170` — `menu_*` actions belong to the `.ui`
  context.
- `src/app/engine.zig:209-255` — `handleEvents`: `shouldDeliverEvent` filters
  before state dispatch; consumed events skip the router. `:263-291`
  `applyFrameControls`: pause/resume through `FrameCommands`. `:364-368`
  overlay top-up after state render. `:460-475` `applyTransitions`.
- `src/app/pause_controller.zig:89-128` — `enter`/`exit` own `resumeActive`
  and the time-loop reset. `reconcileWithStateStack` (`:56-62`) only clears
  the handle.
- `src/render/renderer.zig:196-212` — `k_overlay_command_headroom = 16`,
  `k_stacked_state_ui_headroom = 32`. `src/game/render_prep.zig:330-339` —
  `spriteCommandCapacity` adds the stacked-UI headroom to the gameplay
  reservation.
- Asset lookups for icons: `src/assets/runtime_assets.zig:106-113` `sprite(id)`
  (O(1)), `:135` `spriteAtlasMeta`, `src/assets/sprite_atlas_meta.zig:123`
  `sourceRectForId`. Per-entity sprite refs: `src/game/data_system/visual.zig:309-355`
  (`AssetReferenceStore`: `sprite` + `atlas_entry_id`).
- Slice 53A: `TextLabelSystem`, `clipSprite`/clipped submit facades.

### Architecture notes

- **Mode decision: retained, state-owned, data-declared screens, drawn by an
  immediate walk each frame.**
  - Not immediate-mode, for three reasons:
    1. `State.handleEvent` must return `consumed` at event time
       (`engine.zig:239-242`), but an IMGUI only resolves focus and hits during
       the next declaration pass.
    2. IMGUI identity relies on per-frame ID or label hashing
       (`.claude/rules/memory-performance.md`).
    3. IMGUI re-runs layout every frame.
  - Not VoidLight's retained tree: it uses string IDs, `std::function`
    callbacks, `shared_ptr` components, and a singleton.
  - **Chosen design.** Each screen-owning state holds a `UiScreen(W)`, where
    `W` is that state's own `enum(u8)` of widgets.
    - Widgets are declared once in the state's `init`, as pure data with no
      services.
    - Focus moves synchronously inside `handleEvent`.
    - Activations become typed `UiEvent(W)` records that the owner drains in
      `update`, where `UpdateContext` provides transitions, audio, and
      settings.
    - Layout runs only when something is dirty; drawing walks fixed arrays.
  - **Fit with the state stack.** Modal focus scoping is the state stack
    itself: a modal state blocks events below it. Input-routing policy is
    unchanged: screens consume only UI actions.
- **Files.** `src/game/ui.zig` fronts `src/game/ui/` (same pattern as
  `data_system.zig`):
  - `types.zig`
  - `screen.zig` — the generic shell
  - `layout.zig` — pure solver
  - `focus.zig` — pure navigation
  - `draw.zig`
  - `theme.zig`

  Also new: `src/game/confirm_dialog_state.zig`, and the asset
  `assets/ui/theme.zon`. `src/game/menu_view.zig` is deleted.
- **Generic shell, non-generic core.** `pub fn UiScreen(comptime W: type)
  type` comptime-asserts that `W` is `enum(u8)` with at most
  `k_max_widgets_per_screen = 64` tags. Storage is comptime-sized fixed SoA
  arrays `[n]T`, one per column. This is a named exception to
  `MultiArrayList`: capacity equals `W`'s cardinality, rows never grow or
  shrink, and nothing is allocated. Layout, focus, and draw are non-generic
  functions over column slices, so they compile once and are tested without a
  `W`.
- **Columns.**
  - `kind: WidgetKind`
  - `parent: u8` (`k_root = 0xFF`)
  - `layout: LayoutSpec`
  - `rect: Rect` — computed and retained, so pointer hit-testing can be added
    later without restructuring
  - `flags: packed struct(u8) { visible, enabled, focusable, text_dirty,
    value_dirty, … }`
  - `style: StyleRole`
  - `font: UiFontRole`
  - `text: [k_widget_text_capacity]u8` + `text_len: u8`
  - `label`, `value_label: TextLabelId`
  - `value, min, max, step: i32`
  - `value_format: enum { none, percent, integer }`
  - `axis: enum { horizontal, vertical }`
  - `sprite: ?SpriteRef { asset: SpriteAssetId, atlas_entry: ?u16 }` plus a
    resolved draw cache (`TextureId` + source)
  - `hint: []const u8` (static literal)
  - `measured: [2]f32`
- **`WidgetKind` in this slice** (each has a consumer in this slice):
  `label, button, slider, progress, image, panel, vstack, hstack, scroll`.
  - Deferred to their first consumers: `toggle` and `choice` (Slice 54),
    `list` (Slice 44), and the inventory grid, `toast` primitive,
    `live_modal_overlay` policy preset, and `PendingPlayerActions` UI→gameplay
    queue (Slice 57B, which 63 reuses).
  - Text input, pointer/mouse, hover tooltips, and the event log are Slices
    67A (pointer, tooltips), 67B (event log), and 67C (text input). No dead
    tags.
- **Layout model** (`layout.zig`, pure, O(n), no recursion, no allocation).
  - **Canvas:** the state's `width × height`, i.e. the AppConfig logical size
    (1280×720).
  - **Types:**
    - `Anchor = enum(u4) { top_left, top, top_right, left, center, right,
      bottom_left, bottom, bottom_right }`
    - `Dim = union(enum) { fit, fixed: f32, fill }`
    - `LayoutSpec { anchor = .top_left, offset: [2]f32 = .{ 0, 0 }, width: Dim
      = .fit, height: Dim = .fit, padding: f32 = 0, gap: f32 = 0, cross:
      CrossAlign = .stretch }`
  - **Declaration order:** pre-order (parent before child), validated by
    `build()`.
  - **Measure (reverse pass):**
    - Leaves: label logical size from `TextLabelSystem` plus theme padding;
      slider/progress use the theme minimum; image uses the sprite source
      size.
    - Stacks: sum along the main axis plus gaps, max on the cross axis, plus
      padding.
    - Panels: max child extent plus padding.
    - Scroll: like a vstack for its content, but its own height comes from its
      spec.
  - **Arrange (forward pass):**
    - Root and panel children: anchored inside the parent content rect, plus
      offset.
    - Stack children: placed sequentially; `fill` children split the remaining
      main-axis space equally.
    - Scroll children: placed sequentially minus `scroll_offset`.
  - **Rounding and scale:** final rects round to whole logical pixels. Every
    metric and fixed `Dim` is multiplied by ui_scale (Slice 54 wires the
    setting; this slice uses 100%).
  - **Relayout triggers:**
    - a text or value change that alters the measured size
    - a visibility change
    - `labels.layoutEpoch()` changes
    - `ui_scale` changes
    - the canvas changes
  - Otherwise no layout work runs per frame. Grid and flow layouts are out of
    scope for v1.
- **Focus** (`focus.zig`, pure).
  - **Order:** focus order is declaration order over visible + enabled +
    focusable widgets.
  - **Up/down:** `menu_up`/`menu_down` move to the previous/next widget and
    wrap, matching `menu_view.changeSelection`.
  - **Left/right in a hstack:** these move between focusable siblings, unless
    the focused widget is a value widget (slider; later toggle/choice). Value
    widgets consume left/right and adjust by `step`, clamped.
  - **Auto-scroll:** a focus change scrolls the nearest scroll ancestor so the
    focused rect is inside its clip.
  - **Initial focus:** the first focusable widget, or whatever
    `screen.setFocus` set.
  - Nested scroll containers are rejected at `build()`.
- **New input contract: `EventContext`** (`state.zig`).
  - Shape: `pub const EventContext = struct { transitions: *StateTransitions,
    press: ?ActionPress }`, with `pub const ActionPress = struct { action:
    Action, repeat: bool }` in `input.zig`.
  - The VTable becomes `handle_event: *const fn (*anyopaque, *const
    c.SDL_Event, EventContext) anyerror!bool`, and `StateStack.handleEvent`
    takes `(event, context)`.
  - `Engine.handleEvents` resolves `press` once per delivered event through
    the new `input.actionPressForEvent(event) ?ActionPress`: key-down sets the
    repeat flag from the event; gamepad button-down is always `repeat =
    false`.
  - This replaces the per-state `actionForPressEvent` calls. The raw event is
    still passed, because Slice 44 capture needs it.
  - Slice 44 later changes only the table `actionPressForEvent` reads from;
    states do not change.
  - Every state's `handleEvent` (including `GameDemoState` and the test states
    in `state.zig`) moves to the new signature.
- **`UiScreen.handleAction(press: ActionPress) bool`.**
  - It consumes:
    - `menu_up/down/left/right` — repeat accepted, for these four only
    - `resume_game` as confirm — repeat ignored; a button emits `activated`
    - `quit` as back — repeat ignored; emits `cancelled`
  - It returns `false` for every other action (`pause`,
    `toggle_debug_overlay`, gameplay actions), so `FrameCommands` and F2
    behave as they do today.
- **Events.** `UiEvent(W) = union(enum) { activated: W, value_changed: struct
  { widget: W, value: i32 }, cancelled }`, stored in a fixed ring of
  `k_ui_event_queue_capacity = 16`. On overflow the newest event is dropped and
  a Debug counter bumps. The owner drains with `screen.nextEvent()` in
  `update`. A `UiEvent` never writes simulation state directly: this slice's
  screens only drive app-level transitions and settings. UI-originated
  gameplay requests arrive with Slice 57B's `PendingPlayerActions` queue,
  which the pipeline drains in `main_thread_inputs` and replay format v3
  records (Slice 57B; v2 is Slice 64C's header extension, Table T1).
- **Draw** (`draw.zig`).
  - **Reserve first:** `renderer.reserveSpriteCommands(spriteCommandCount() +
    screen.drawCommandBound() + Renderer.k_overlay_command_headroom)`. The
    extra overlay headroom keeps Engine's post-render top-up
    (`engine.zig:364-368`) inside the high-water. Slice 60 lands later and
    adds a screen fade after state render; it introduces
    `Renderer.k_post_state_command_headroom = k_overlay_command_headroom +
    k_screen_fade_command_headroom` and switches this formula to it (60 lands
    second, so it owns that edit).
  - **Stacked-UI headroom retired.** Every state's reserve covers its own
    content bound plus the post-state headroom, so
    `Renderer.k_stacked_state_ui_headroom` (32, a hand-sized guess at
    stacked menu content) and its `>= 2 × k_overlay_command_headroom`
    comptime assert are deleted. `render_prep.spriteCommandCapacity` adds
    `Renderer.k_overlay_command_headroom` and `hud.drawCommandBound()`
    instead. Engine's overlay top-up then stays inside the high-water by
    construction, not by `ArrayList` growth slack. Slice 60's planned
    32 → 40 bump of the deleted constant is void; 60 only switches these
    reserve sites to `k_post_state_command_headroom`.
  - **The bound** is a capacity fixed once at `build()`. It never tracks
    live text, so a longer `setText` cannot grow the reservation on the
    render path. It is the sum of per-kind rect counts, plus 128 glyph quads
    (`k_widget_text_capacity`; glyph quads ≤ UTF-8 bytes) per widget with a
    `label`, plus 8 per widget with a `value_label` (the 8-byte value-text
    buffer):
    - panel: 1 + 4 border rects
    - slider: 3
    - progress: 2
    - scrollbar: 2
    - focus highlight: 1
  - **Passes:** four, all in pre-order, all at `RenderOrder.uiInStack(context.ui_stack_order,
    depth)` so the stream stays nondecreasing as `SpriteBatch` requires:
    1. `.background` — overlay/backdrop
    2. `.panel` — panels, tracks, scroll background
    3. `.highlight` — focus highlight, fills, scrollbar thumb
    4. `.text` — labels, value text, images
  - Widgets inside a scroll draw through the clipped facades with the scroll
    rect.
  - No new `UiDepth` tags.
- **Text.**
  - Labels materialize lazily in `render`, because states have no
    `TextService` at `init`: `if (!labels.isAlive(id))` recreate; `if
    (text_dirty)` call `setText`.
  - Color comes from the theme per draw, by style × {normal, focused,
    disabled}. Focus movement therefore costs no text work, unlike
    `settings_menu_state.zig:219-241`.
  - Value text (slider percent) is formatted with `std.fmt.bufPrint` into an
    8-byte buffer, and only when the value changes.
- **Theme as data.**
  - `UiTheme` (`ui/theme.zig`) uses field defaults equal to the shipped look,
    with the palette taken from `main_menu_state.zig:43-47`,
    `settings_menu_state.zig:65-69`, and `pause_state.zig:29-32`.
  - **Fields:**
    - `format_version: u16 = 1`
    - `fonts: UiFontTable = default_ui_font_table`
    - `colors { overlay, panel, panel_border, focus, text, text_focused,
      text_disabled, title, hint, danger, success, warning, track, fill,
      scrollbar }`
    - `metrics { row_height = 36, padding = 12, gap = 8, border = 2,
      slider_width = 220, track_height = 10, focus_inset = 4,
      scrollbar_width = 6, panel_min_width = 380, dialog_width = 480 }`
    - `StyleRole = enum { normal, title, hint, danger, success, warning }` —
      VoidLight's button variants expressed as data.
  - **Loading:** `assets/ui/theme.zon` is parsed at `Engine.init` with
    `std.zon.parse.fromSlice` (`ignore_unknown_fields = false`); the version is
    checked.
  - **Validation:**
    - colors are finite and inside [0,1]
    - metrics are in (0, 512]
    - fonts pass `FontDesc.validate`
  - A missing or invalid theme fails startup, the same as registered atlas
    sidecars (`docs/rendering-assets-shaders.md:420-423`), because it is a
    developer asset.
  - Engine owns `ui_theme` plus an arena for its strings for the app lifetime;
    `theme.fonts` replaces `default_ui_font_table` in `initLabels`; states
    receive `RenderContext.ui_theme: *const UiTheme`.
  - `build.zig` adds a test import `ui_theme_zon` (like `tilemap_frag_glsl`)
    so `zig build test` parses the shipped theme.
- **Modal dialog is a state, not a widget.** `ConfirmDialogState { title,
  message (wrapped), confirm_label, cancel_label, danger: bool, result:
  *ConfirmResult }` is pushed with `pushModal`.
  `ConfirmResult = enum { idle, confirmed, cancelled }` lives in the parent
  state and is polled in the parent's `update`. This is the same parent-outlives-modal
  lifetime argument as `main_menu_state.zig:173-181`.
- **Pause menu and resume request.**
  - `PauseState` becomes an interactive menu: **Resume / Quit Game** (Quit
    Game confirms first).
  - Settings and Quit to Main Menu arrive in Slice 54: they need Engine-owned
    settings. Today volumes are state-threaded (`loading_state.zig:53-55,
    :165-184`), so adding those items now would reset or misreport volumes.
  - **Resume path:**
    1. New `StateTransitions.resumeGameplay()` queues `Request.resume_gameplay`.
    2. That sets `TransitionApplyResult.resume_requested`, mirroring
       `quit_requested`.
    3. Engine records `pending_resume`.
    4. `applyFrameControls` calls `pause.exit(...)` when the game is paused and
       `!frame_policy.should_pause_gameplay`.

    `resumeActive` and the time reset stay owned by `PauseController`.
  - **Key changes:**
    - The pause menu consumes `quit` (Esc/B) as Resume. This is a documented
      behavior change: today Esc/B quits the app from pause.
    - It does not consume `pause`, so P/Start still resumes through
      `FrameCommands`, unchanged.
- **Main menu.** Start / Settings / Quit. Quit, and Esc/B, open a confirm
  dialog before `transitions.quit()`. Documented change: Esc no longer quits
  instantly from the main menu.
- **Settings menu (interim, until Slice 54).** Three sliders (range 0..10,
  step 1; `RuntimeAudioSettings` unchanged) + Back + a hint footer driven by
  the focused widget's `hint`.
- **HUD primitives.**
  - **Widgets:**
    - `progress` — horizontal or vertical; value/max
    - `image` — `SpriteRef` resolved through `RuntimeAssets.sprite` +
      `spriteAtlasMeta(...).sourceRectForId` when dirty; the resolved cache is
      render-side screen state, not `DataSystem`
    - `label` — numeric text, set only when the number changes
  - **Demo HUD:** `GameDemoState` owns `hud: UiScreen(HudWidget)`. It is
    non-focusable and never consumes input. It shows:
    - a vertical depth gauge: `player.current_level` / deepest level
    - a "Level N" label
    - a "Destroyed N" label, counting `destructible_destroyed` events
      (`simulation.zig:163`)
    - the player portrait, from the player's `AssetReferenceStore` row; if the
      art is unavailable, nothing is drawn
  - **Updates:** values are pushed from `update` with a dirty compare
    (VoidLight HudController's `m_last*Pct` pattern).
  - **Drawing:** the HUD draws after the world in `GameDemoState.render`;
    `render_prep.spriteCommandCapacity` adds `hud.drawCommandBound()`.
- **Capacities, ceilings, and budgets.** Nothing grows after `build()`;
  overflowing content scrolls.
  - Per-screen widget capacity is `W`'s cardinality, sized at comptime from
    the screen's authored widget enum. `k_max_widgets_per_screen = 64` is a
    comptime safety ceiling, not the working size: it bounds the per-event
    focus/hit walk and the draw bound (`parent: u8` alone would allow 255).
  - `k_widget_text_capacity = 128` bytes is a fixed per-row field width (an
    inline `[128]u8` column with a `u8` length); `setText` truncates on a
    UTF-8 boundary.
  - `k_ui_event_queue_capacity = 16` is a per-frame budget: the ring is
    drained every `update`, and overflow drops the newest event with a
    Debug counter.
  - one scroll level
- **Errors.** `UiBuildError = error{ UiWidgetMissing, UiWidgetDuplicate,
  UiParentOrder, UiParentNotContainer, UiNestedScroll }`, raised by
  `screen.build()` in state `init` (cold).
  `UiThemeError = error{ UiThemeParse, UiThemeVersionUnsupported,
  UiThemeInvalidColor, UiThemeInvalidMetric }`, plus the `FontDesc`
  validation errors.
- **Threading.** Serial, main thread (≤ 64 widgets × 4 passes).
- **Diagnostics** (`game` scope): a Debug-only layout-overflow warn, once per
  screen per layout epoch, gated by `logging.enabled`; theme load logs `info`,
  or `err` with the ZON `Diagnostics`.

### Checklist

- [ ] `ui/layout.zig` solver, with tests: all 9 anchors, fit/fixed/fill,
      stack gap/padding/cross-align, equal `fill` split, scroll offset,
      rounding, ui_scale multiplier.
- [ ] `ui/focus.zig`, with tests: wrap, skip hidden/disabled, hstack
      left/right, value widgets consume left/right (clamped), auto-scroll.
- [ ] `ui/screen.zig` `UiScreen(W)`: `build` validation (each error),
      `handleAction`, the event ring (overflow drop), repeat policy,
      `setText` (UTF-8 truncate), `setValue`/`setVisible`/`setEnabled`/`setFocus`.
- [ ] `ui/draw.zig`: passes, reservation bound, clipped scroll children.
      Tests on a CPU-only renderer (the `ai_debug_overlay.zig:614` fixture
      pattern) assert nondecreasing order, the focus highlight, and clipped
      rects. The bound is fixed at `build()`: a test sets a 1-byte text, then
      a 128-byte text and a new slider value, and `drawCommandBound()` is
      unchanged.
- [ ] `FailingAllocator` proofs:
      - warmed `UiScreen.render` with nothing dirty
      - `handleAction` + `nextEvent`
      - a dirty layout pass, which also allocates zero
      - overlay top-up after a UI screen's reserve, mirroring renderer.zig's
        "engine overlay top-up …" test
      - a dirty pass after `setText` lengthens a label to 128 bytes: the
        reservation does not grow
- [ ] Retire `Renderer.k_stacked_state_ui_headroom` and its comptime assert;
      `render_prep.spriteCommandCapacity` adds `k_overlay_command_headroom` +
      `hud.drawCommandBound()`. Rewrite renderer.zig's "engine overlay top-up
      after stacked UI fully consumes its headroom stays allocation-free" test
      to the per-screen reserve rule. `FailingAllocator` proofs on a CPU-only
      renderer after one warmed frame: (a) a gameplay-only frame plus the
      Engine overlay top-up; (b) gameplay → `PauseState` →
      `ConfirmDialogState` plus the top-up. Both allocate zero.
- [ ] `ui/theme.zig` + `assets/ui/theme.zon` + the `ui_theme_zon` test
      import. Tests: the shipped theme parses; unknown field, bad version, and
      out-of-range color are each rejected.
- [ ] `state.zig`: `EventContext`, the VTable change, `resumeGameplay` +
      `resume_requested`. `input.zig`: `ActionPress` + `actionPressForEvent`.
      `engine.zig`: per-event resolve and `pending_resume` → `pause.exit`.
      Update the existing `state.zig` handleEvent tests; add a test that the
      resume request reaches the pause exit.
- [ ] Engine: load the theme, pass `theme.fonts` to `initLabels`, set
      `RenderContext.ui_theme`.
- [ ] Migrate `MainMenuState`, `SettingsMenuState` (interim), `PauseState`,
      and `LoadingState` to `UiScreen`. Add `ConfirmDialogState`. Delete
      `menu_view.zig`. Port the existing keyboard + gamepad named-action test
      pairs to `EventContext`.
- [ ] `GameDemoState` HUD + reservation. Tests: values reach labels and
      progress only when they change; the HUD never consumes events.
- [ ] Layout-fit tests: each migrated screen's solved rects lie inside
      1280×720 at ui_scale 100, using synthetic measured text sizes.
- [ ] Bench groups (one group per workload, `suite.zig` convention):
      `ui-layout` (solve a 64-widget synthetic screen) and `ui-screen-draw`
      (warmed settings-sized screen into a CPU-only renderer).
- [ ] Docs:
      - `docs/state-stack-and-input.md`: EventContext, menu contract, pause
        menu, the Esc/B semantics changes, resume request
      - `docs/rendering-assets-shaders.md`: UI toolkit section (passes,
        clipping, theme)
      - `docs/architecture.md`: source layout (replace the `menu_view.zig`
        bullet) and a UI ownership paragraph
      - `src/tests.zig` registers `game/ui/*`

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build bench -- --group ui-layout` and `--group ui-screen-draw` run;
      baselines are recorded in Status.
- [ ] Manual (needs a display):
      - main menu, settings, pause, and confirm dialogs are navigable by
        keyboard (arrows / Enter / Esc) and gamepad (D-pad / South / East)
      - F2 still toggles the overlay over menus
      - P/Start resumes from pause; Esc/B in pause resumes
      - Quit Game → confirm quits
      - the HUD gauge and labels track digging and destroying
- [ ] Test parity: the ported keyboard/gamepad activation tests reach the same
      outcomes as the pre-migration suites.
- [ ] Review check: `src/game/ui/` has no string IDs, callbacks, hash lookups,
      `render/gpu/*` imports, or SDL handles.
- [ ] Review check: `k_stacked_state_ui_headroom` is gone, and every render
      reserve term is a build-time bound, a load-time capacity, or
      `k_overlay_command_headroom`, never a live text length.

### VoidLight reference

- **Port (VL `include/managers/UIManager.hpp`):**
  - `:36-53` component types — the v1 subset here
  - `:56-62` layout types — stack + anchor only
  - `:65-77` position modes → `Anchor`
  - `:134-162` `UIStyle` → `UiTheme` colors/metrics/`StyleRole`
  - `:402-408` keyboard selection + `simulateClick` → `focus.zig` + confirm
    `activated`
- **Port (VL `include/utils/MenuNavigation.hpp:15-54`):** linear nav order
  with wrap.
- **Port (VL `src/managers/UIManager.cpp`):**
  - `:1308-1650` theme tables — copy palette values into `theme.zon` if
    wanted
  - `:2183-2207` stack/anchor layout
  - `:2531-2635` resize repositioning → layout dirty on canvas change
  - `:2646-3352` modal render cutoff → ZL gets this from the state-stack
    `render_below` policy
- **Port (VL `include/controllers/ui/HudController.hpp:1-128`):** HUD bars,
  labels, and icons with dirty-compare pushes.
- **Do not port:**
  - string component IDs and `parentId` strings (`UIManager.hpp:165-237`)
  - `std::function` callbacks (`:219-224`) and text/list binding lambdas
  - `UITheme`'s `unordered_map` (`:254-262`)
  - the singleton `Instance()` (`:280`)
  - mouse hover/click handling (`UIManager.cpp:1902-2094`) — (Slice 67A)
  - flow/grid layouts
  - EVENT_LOG and INPUT_FIELD
  - `MenuNavigation`'s static `s_keyboardNavUsed`
  - HudController's EventManager subscriptions and `weak_ptr<Player>`
  - InventoryController (`src/controllers/ui/InventoryController.cpp`, 1.5k
    lines) — Slice 57B builds the inventory UI from these primitives

