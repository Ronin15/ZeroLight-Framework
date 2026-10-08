## Slice 54: Persistent Settings

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 53B (widgets, `ConfirmDialogState`,
`EventContext`, pause menu). App-layer work. Independent of the AI /
simulation tracks.

Settings are app-level user preferences, not simulation state. They are not
the "persistence beyond Slice 46" that the Ground Rules gate. They live in
`settings.zon`; the Slice 46 save format has no settings section.

Goal: an Engine-owned, typed `RuntimeSettings` (audio, video, accessibility;
Slice 44 adds input bindings) that:
- persists to `SDL_GetPrefPath(org, app)/settings.zon` in a versioned,
  strictly validated ZON format
- writes atomically (temp + fsync + rename)
- falls back to defaults with a logged warning when the file is missing or
  corrupt, keeping a backup of the rejected file
- is applied before the window, audio, and renderer are created at startup
- applies live when changed from the settings menu (now on 53B widgets),
  which the pause menu can also open

### Current foundation

- `src/config.zig:15-37` `AppConfig` (`app_name`, `frames_in_flight`,
  `present_mode`, `resolution_policy`, `audio`) and `:39-68` `AudioConfig`
  validation. `build.zig:78-79` has `-Dapp-name`/`-Dwindow-title` but no
  organization option.
- `src/app/engine.zig:67-173` init order:
  1. validate
  2. SDL init (`:77-79`)
  3. gamepad
  4. window (`:86-95`)
  5. `AssetStore`
  6. `AudioService.init(app_config.audio)` (`:98`)
  7. `Renderer.init(app_config)` (`:104`)
  8. text
  9. `bootstrapStartupState(app_config)` (`:124`, `:574-590`)

  `:567-572` `minimumWindowSizeForPolicy`.
- `src/render/gpu/device.zig:36-52` `configureSwapchain`, `:77-101`
  `selectPresentMode` (falls back when unsupported). Per SDL headers, both
  `SDL_SetGPUAllowedFramesInFlight` (stalls/flushes) and
  `SDL_SetGPUSwapchainParameters` can be changed at runtime.
- `src/game/settings_menu_state.zig:24-45` `RuntimeAudioSettings` (0..10) is
  threaded by value through `MainMenuState` (`:30, :60, :165, :181`) and
  `LoadingState` (`:53-55, :165-184`). Volume edits emit `AudioCommandBuffer`
  gain commands (`:177-209`), and the test at `:353-365` pins "failed audio
  command leaves the runtime value unchanged".
- `src/app/resolution.zig:10-15` `ScaleMode`, `:44-51` `ResolutionPolicy`.
  `src/platform/sdl.zig:35-58` `Window` + `composeWindowFlags`.
- `src/assets/assets.zig:30` — limited `readFileAlloc` pattern.
- Zig 0.17 std: `std.zon.parse.fromSlice` (`Options.ignore_unknown_fields`,
  `Diagnostics`), `std.zon.stringify.serialize`,
  `std.Io.Dir.createFileAtomic(io, path, .{ .replace = true })` +
  `File.sync` + `File.Atomic.replace`/`deinit`.
- Slice 53B: `UiScreen`, `ConfirmDialogState`, pause menu, `EventContext`.

### Architecture notes

- **Files and owners.**
  - `src/app/user_storage.zig` — `UserStorage`: pref-dir resolution,
    `readFile`, `writeFileAtomic`, `backupRejected`. Slice 46 reuses it.
  - `src/app/settings.zig` — types, defaults, validation, `SettingsStore`.
  - `src/app/settings_file.zig` — versioned ZON schemas,
    parse/upgrade/serialize. Pure, no I/O.
  - `src/platform/sdl.zig` gains `prefPath(allocator, org, app) !?[]u8`
    (copies, then `SDL_free`), `Window.setFullscreen(bool) !void`,
    `Window.clearMinimumSize()`, and a `fullscreen` parameter on
    `composeWindowFlags`.
  - Logging uses the `app` scope.
- **App identity.**
  - `AppConfig.org_name: []const u8 = "HammerForgedGames"`, from the new build
    option `-Dorg-name`. The default matches VoidLight's `SDL_GetPrefPath` org
    and the copyright holder. `org_name` is the single human org string.
  - The pref-path app string is `app_name`; SDL requires it never changes once
    shipped.
  - `AppConfig.validate` requires 1..64 bytes for both, else
    `error.InvalidAppIdentity`, with a `logInvalidConfig` arm: `org_name`
    allows `[A-Za-z0-9 _-]`; `app_name` allows `[A-Za-z0-9_-]` with no space,
    the same set Slice 52B checks for `-Dapp-name` at configure, because it
    also names files, folders, and the `.desktop` entry.
  - **Bundle id.** Slice 52B landed first with `-Dbundle-id` defaulting to
    `com.hammerforgedgames.<app>`. This slice lands second, so it switches
    that default to derive from `org_name`: `com.<org>.<app>`, each segment
    lowercased with spaces removed and `_` mapped to `-` (CFBundleIdentifier
    allows only alphanumerics, `-`, and `.`). The default output is unchanged
    (`HammerForgedGames` → `hammerforgedgames`), and an explicit
    `-Dbundle-id` still wins.
  - **App identity table.** This slice adds the `-Dorg-name` option and the
    `SDL_GetPrefPath` consumer to 52B's "App identity" table in
    `docs/development-workflow.md` (org, `app_name`, `bundle_id`, version).
- **Types** (`settings.zig`):
  - `RuntimeSettings { audio: AudioSettings, video: VideoSettings,
    accessibility: AccessibilitySettings }`
  - `AudioSettings { master_percent: u8, sfx_percent: u8, music_percent: u8,
    muted: bool }` — percents 0..100, step `k_volume_step_percent = 5`
  - `VideoSettings { window_mode: WindowMode, present_mode:
    config.PresentMode, frames_in_flight: u8, scale_mode: resolution.ScaleMode
    }` — `WindowMode = enum { windowed, borderless_fullscreen }`,
    `frames_in_flight` 1..3
  - `AccessibilitySettings { ui_scale: UiScale }` — `UiScale = enum(u8) {
    percent_100, percent_125, percent_150 }`
  - `RuntimeSettings.defaults(app_config)` is the single defaults source,
    derived from AppConfig: master 100, sfx 85, music 55 (gain × 100,
    rounded), plus the AppConfig present mode, frames in flight, and scale
    mode.
  - `applyTo(app_config) AppConfig` produces the effective startup config.
  - "Resolution scale" means `ScaleMode`. The renderer draws straight to the
    swapchain with no internal render target, so there is no render-resolution
    percentage to persist.
  - Every v1 field has a runtime consumer. The schema grows by appending
    fields, each with its consumer and an `upgradeVNToVN+1` step, bumping
    the live version (`.claude/rules/simulation.md`): Slice 44 adds `input`
    bindings, and Slice 60 owns its camera options (`VideoSettings.zoom_index:
    u8`, validated against its zoom level count). Slice 67A switches keyboard
    bindings to scancodes, Slice 70B adds `video.scene_resolution` (planned
    chain: Table T2 in the
    [VoidLight port track](../tracks/voidlight-port.md)).
  - `RuntimeAudioSettings` and its 0..10 scale are deleted.
- **Format: ZON.**
  - Why ZON:
    - `std.zon` parses straight into these structs and enums: enum literals
      like `.vsync` are validated by the parser, and unknown fields are
      rejected.
    - It is human-readable and hand-editable.
    - There is no field-walking code to write.
  - Why not JSON: it would need a manual walker or `std.json` with less
    natural enum and number literals.
  - Why not binary: it buys nothing for a file under 4 KiB and is not
    user-inspectable.
  - Saves (Slice 46) stay binary because they hold large dense columns.
- **Schema v1.** `k_settings_format_version: u16 = 1`. `SettingsFileV1 =
  struct { format_version: u16, audio: AudioSettings = …, video:
  VideoSettings = …, accessibility: AccessibilitySettings = … }`. An omitted
  section or field takes its default; unknown fields, wrong types, and unknown
  enum literals reject the file. Example:
  `.{ .format_version = 1, .audio = .{ .master_percent = 100, .sfx_percent = 85, .music_percent = 55, .muted = false }, .video = .{ .window_mode = .windowed, .present_mode = .vsync, .frames_in_flight = 3, .scale_mode = .fit }, .accessibility = .{ .ui_scale = .percent_100 } }`.
- **Load** (cold, inside `Engine.init`; never fails init):
  1. `UserStorage.readFile("settings.zon", k_settings_max_bytes = 64 * 1024)`
     → `dupeSentinel`.
  2. Parse a `VersionProbe { format_version: u16 }` with
     `ignore_unknown_fields = true`.
  3. Dispatch on the version:
     - equals current → strict parse
     - lower than current → parse the old schema, then the `upgradeVNToVN+1`
       chain (Slice 44, the first appending slice in the suggested order,
       adds the first step)
     - 0 or newer than current → reject
  4. Semantic validation: percents ≤ 100, `frames_in_flight` in 1..3. A
     percent that is in range but off the `k_volume_step_percent = 5` grid
     (a hand edit such as `37`) is accepted and snapped to the nearest
     multiple of 5 (`37` → `35`, `38` → `40`; integers have no ties), with
     one `debug` log. Only that field changes; the next save writes the
     snapped value. Rejecting the whole file for an in-range fine value
     would discard every other setting.
  5. Produce `RuntimeSettings`.
  6. (Added by Slice 67.) Any load that ran an upgrade step sets
     `save_requested` so the latest version is written once, after any
     deferred step (Slice 67A's keymap-ready key migration) completes (Slice
     67A's migration freeze).

  Parse scratch uses a local `ArenaAllocator` wrapping the store allocator.

  Outcomes:
  - **Missing file:** defaults, `debug` log.
  - **Any rejection:** rename `settings.zon` → `settings.rejected.zon`
    (replacing an older backup), `warn` with the ZON `Diagnostics` or the
    validation error, use defaults.
  - **Pref dir unavailable:** defaults, persistence disabled, `warn` once.
- **Save.**
  - Serialize `SettingsFileV{latest}` with `std.zon.stringify` (whitespace)
    into an `std.Io.Writer.Allocating`, then
    `UserStorage.writeFileAtomic("settings.zon", bytes)`:
    `createFileAtomic(.replace = true)` → write → `file.sync` → `replace` →
    `deinit`.
  - **On error:** `warn`, keep the in-memory settings, set
    `last_save_failed = true` so the menu shows "Settings could not be saved".
  - **Triggers:** only `requestSave()` (settings Back when dirty, reset to
    defaults, and Slice 44 rebind commits) and `Engine.deinit` when dirty.
    Never per frame.
  - **Main thread:** the payload is fixed and tiny (< 4 KiB, not a scaling
    workload), so the write runs on the main thread and does not go through a
    worker lane. The fsync can hitch one frame of a user-initiated menu
    action, which is accepted.
- **`SettingsStore`.** An Engine field, never a global.
  - **Data:** pure data plus methods: `current`, `persisted`, `defaults`
    (`RuntimeSettings`), `pending_video: bool`, `save_requested: bool`,
    `last_save_failed: bool`. Methods that do I/O take `*UserStorage`
    (Engine-owned, passed per call).
  - **Setters for states** (via `UpdateContext.settings`):
    - `setAudioPercent(bus: enum { master, sfx, music }, percent: u8, audio:
      *AudioCommandBuffer) !void` — issues the command first and stores the
      value only on success, preserving the `:353-365` semantics
    - `setMuted(bool, audio) !void` — mute sends a master gain of 0; unmute
      restores the master percent
    - `setVideo(VideoSettings) void` — sets `pending_video`
    - `setUiScale(UiScale) void`
    - `resetToDefaults(audio) !void`
    - `requestSave() void`
    - `isDirty() bool` — `current != persisted`
  - **Engine-only:** `takePendingVideo() ?VideoSettings`,
    `flushSave(*UserStorage) void`.
- **Startup apply order** (`Engine.init`):
  1. `validateConfig`
  2. SDL init
  3. gamepad
  4. `user_storage = UserStorage.init(allocator, io, org_name, app_name)` —
     after SDL init, because it calls `SDL_GetPrefPath`
  5. `settings = SettingsStore.load(allocator, &user_storage,
     RuntimeSettings.defaults(app_config))`
  6. `effective = settings.current.applyTo(app_config)`, then
     `effective.validate()`
  7. create the window with `composeWindowFlags(…, fullscreen =
     borderless_fullscreen)` — SDL3's `SDL_WINDOW_FULLSCREEN` with no mode set
     is desktop fullscreen
  8. `AudioService.init(effective.audio)` — muted means a master gain of 0
  9. `Renderer.init(effective)`
  10. text, labels, and theme, with the ui_scale
  11. states

  `Engine.app_config` keeps the base config, which is the reset source.
  `MainMenuState.init` drops its `audio_config` parameter.
- **Runtime apply.** `Engine.applyPendingSettings()` runs after each
  `update`'s `applyTransitions` and before the audio drain.
  - If there is a pending video change:
    - `window.setFullscreen(…)`
    - `renderer.setPresentMode(mode)` returns the mode actually applied; it is
      a facade over `gpu/device.zig` `selectPresentMode` +
      `SDL_SetGPUSwapchainParameters`
    - `renderer.setFramesInFlight(n)` stalls by SDL design
    - `renderer.setResolutionPolicy(.{ base logical size, scale_mode })`
    - the window minimum size comes from `minimumWindowSizeForPolicy`; when
      the result is null, `clearMinimumSize`
  - Each failure logs `warn` and reverts that field in `current`, so the UI
    shows reality.
  - After that, `flushSave` runs if a save was requested.
  - `ui_scale` needs no Engine action: it flows through
    `TextService.beginFrame` and `RenderContext`, and screens relayout when it
    differs from the scale they last laid out with.
- **Context wiring.** `UpdateContext.settings: *SettingsStore`,
  `RenderContext.settings: *const RuntimeSettings`. The
  `RuntimeAudioSettings` threading in `MainMenuState`, `LoadingState`, and
  `SettingsMenuState` is removed.
- **New widgets** (53B toolkit; first consumers are here):
  - `toggle`: value 0/1; confirm or left/right flips it; "On"/"Off" value
    text.
  - `choice`: value is an index into a static option table `[]const []const
    u8` (≤ `k_max_choice_options = 8`) with `enabled_mask: u8`; left/right
    cycles with wrap and skips disabled options.
- **Settings screen.** Title, then a scroll containing:
  - **Audio:**
    - Master / SFX / Music sliders: 0..100, step 5, percent format
    - Mute toggle
  - **Video:**
    - Window mode
    - Present mode (VSync / Mailbox / Immediate). Unsupported modes are
      disabled using `renderer.presentModeSupported(mode)`, queried while the
      screen prepares.
    - Frames in flight (1 / 2 / 3)
    - Scale mode (Fit / Integer / Stretch / Overscan)
  - **Accessibility:** UI scale (100 / 125 / 150%)
  - **Reset to defaults** — confirm first

  Below the scroll: Back, a hint label, and a save-status label.
  - Edits apply immediately: audio through commands, video through the
    pending apply, ui_scale on the next frame.
  - Back calls `requestSave()` if dirty, then `pop()`.
- **Pause menu additions.**
  - Settings: `pushModal(SettingsMenuState)`; this is sound now that settings
    are Engine-owned.
  - Quit to Main Menu: confirm, then `transitions.replace(MainMenuState, …)`,
    which replaces the whole stack (`state.zig:613-624`).
- **UI scale.** Multiplies 53B metrics and 53A font sizes. Layout-fit tests at
  100 / 125 / 150; scroll absorbs vertical overflow.
- **Errors.**
  - `SettingsLoadError = error{ SettingsFileTooLarge, SettingsParse,
    SettingsVersionUnsupported, SettingsValueOutOfRange }` — internal, logged,
    never escapes `load`.
  - `UserStorageError = error{ PersistenceUnavailable }` merged with the
    explicitly named `std.Io` create/write/sync/rename error sets — logged by
    callers.
- **Fixed budgets.** 64 KiB read cap. No per-frame work. The parse arena is
  freed after load.

### Checklist

- [ ] `config.zig`/`build.zig`/`main.zig`: add `org_name` + `-Dorg-name` and
      identity validation, with tests (valid, empty, over-long, punctuation,
      a space accepted in `org_name` and rejected in `app_name`). Switch the
      52B `-Dbundle-id` default to derive from `org_name`.
- [ ] `platform/sdl.zig`: `prefPath`, `Window.setFullscreen`/`clearMinimumSize`,
      fullscreen flag composition, plus a pure flag-composition test.
- [ ] `user_storage.zig`, with tests against `std.testing.tmpDir`:
      - the atomic replace leaves no temp file and replaces the old content
      - the rejected backup replaces an older backup
      - an oversized read is rejected
      - a disabled store reports `PersistenceUnavailable`
- [ ] `settings_file.zig`, with tests:
      - round-trip equality
      - an omitted section takes defaults
      - unknown field rejected
      - bad enum literal rejected
      - out-of-range rejected
      - an off-grid in-range percent (`37`) snaps to `35`, and `38` to `40`,
        leaving the other fields untouched
      - version 0 and future versions rejected
      - the version probe tolerates unknown fields
- [ ] `settings.zig`, with tests:
      - `defaults(app_config)` and `applyTo`
      - a failed audio command leaves the value unchanged
      - muted semantics
      - dirty tracking
      - pending video
      - reset
- [ ] Engine: init order, `applyPendingSettings`, `flushSave`, flush in
      `deinit`, contexts. Renderer facades `setPresentMode`/`setFramesInFlight`/
      `setResolutionPolicy`/`presentModeSupported` are thin, GPU-gated, and
      covered manually and by gpu-smoke.
- [ ] Toolkit `toggle` + `choice`, with tests: cycling wraps and skips
      disabled options, and value events fire.
- [ ] Settings screen rebuilt; pause menu gains Settings + Quit to Main Menu;
      `RuntimeAudioSettings` threading removed. Tests: keyboard and gamepad
      passes; Back requests a save only when dirty; Quit to Main Menu replaces
      the stack.
- [ ] UI-scale wiring (`TextService.beginFrame`, layout multiplier), plus
      layout-fit tests for every screen at 100 / 125 / 150.
- [ ] Docs:
      - `docs/architecture.md` Configuration And Diagnostics: settings
        override layer, pref path, apply order, `UserStorage`
      - `docs/state-stack-and-input.md`: settings and pause menus
      - `docs/development-workflow.md`: `-Dorg-name` and the App identity
        table row, per-platform settings location, how to reset (delete
        `settings.zon`)
      - `src/tests.zig` registers the new modules
- [ ] Add the settings-field append rule to `.claude/rules/input-state.md`
      when this lands.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] Manual:
      - change volume, mute, window mode, VSync, frames in flight, scale mode,
        and UI scale, restart, and confirm every value is restored
      - a hand-corrupted `settings.zon` → defaults, one warning, and
        `settings.rejected.zon` exists
      - an unwritable pref dir → session-only settings with a warning
- [ ] Manual (Linux; Windows/macOS when available): fullscreen, present mode,
      frames in flight, and scale mode apply live with no restart.
- [ ] An interrupted write never leaves a truncated `settings.zon`, by the
      temp + fsync + rename design plus the `tmpDir` test.

### VoidLight reference

- **Port:**
  - `src/core/GameEngine.cpp:103-120` — load settings before window creation
    (keep the ordering, not the path).
  - `:342-345` — present mode read from settings.
  - `:548-557` — apply persisted volume and mute at audio init.
  - `:590-599` — the `SDL_GetPrefPath("HammerForgedGames", app)` org string.
  - `include/managers/SettingsManager.hpp` — the idea of typed defaults at
    load.
- **Do not port:**
  - the singleton
  - `std::variant` values behind `category`/`key` string lookups
  - change callbacks and `shared_mutex`
  - `res/settings.json` inside the install directory
    (`src/core/GameEngine.cpp:106-107`)
  - the plain `std::ofstream` write (`src/managers/SettingsManager.cpp:114`)
  - VL's separate `res/input_bindings.json` (`GameEngine.cpp:503-505`;
    bindings live in `settings.zon` via the Slice 44 amendment)

