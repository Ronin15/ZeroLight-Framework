## Slice 54: Persistent Settings

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md), [Slice 52B](slice-52b.md) (bundle-id default) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal: an Engine-owned, typed settings store (audio, video, accessibility;
Slice 44 adds bindings) that persists to the per-user pref directory in a
versioned, strictly validated, hand-editable file; writes atomically; falls
back to defaults with one warning and a backup of a rejected file; applies
before the window, audio, and renderer are created; and applies live from a
settings menu that the pause menu can also open. Settings are app
preferences, never save data and never simulation input (Ground Rules).

### Current foundation

- `src/config.zig` `AppConfig` (`app_name`, `frames_in_flight`,
  `present_mode`, `resolution_policy`, `audio`) with validation;
  `build.zig` has `-Dapp-name` / `-Dwindow-title` and no organization
  option. Nothing calls `SDL_GetPrefPath`.
- `src/app/engine.zig` init order: validate, SDL, gamepad, window,
  `AssetStore`, `AudioService` (from `app_config.audio`), `Renderer` (from
  `app_config`), text, startup state, `ThreadSystem`.
- `src/render/gpu/device.zig` `configureSwapchain` / `selectPresentMode`
  (falls back when unsupported); SDL allows frames-in-flight and swapchain
  parameters to change at runtime.
- `src/game/settings_menu_state.zig` `RuntimeAudioSettings` (0..10) is
  threaded by value through `MainMenuState` and `LoadingState`; volume edits
  emit `AudioCommandBuffer` gain commands, and a test pins "a failed audio
  command leaves the value unchanged".
- `src/app/resolution.zig` `ScaleMode` / `ResolutionPolicy`;
  `src/platform/sdl.zig` `Window` and `composeWindowFlags`. The renderer
  draws straight to the swapchain, so there is no render-resolution
  percentage to persist.
- Zig 0.17 std: `std.zon.parse.fromSlice` (unknown fields rejectable,
  diagnostics), `std.zon.stringify`, and atomic file create/replace with
  sync.
- Slice 53B: `UiScreen`, confirm dialog, pause menu, `EventContext`.

### Architecture notes

- Settings live in `settings.zon` under the pref dir; Slice 46 has no
  settings section. A settings value never feeds simulation state, the
  replay, or the checksum (`.claude/rules/simulation.md` § Determinism).
- The store is an `Engine` field, never a global; methods that do I/O take
  the user-storage owner explicitly (`.claude/rules/engine-design.md`).
  User-storage (pref dir, bounded read, atomic write, rejected-file backup)
  is one app-layer owner that Slices 46 and 66A reuse.
- The schema grows by appending fields, each with its consumer and an
  upgrade step, bumping relative to the live value (Table T2,
  `.claude/rules/simulation.md` § Persistent data). Every field has a
  runtime consumer; no field is added for a future slice.
- Load never fails init: a missing file gives defaults; any rejection
  backs up the file and uses defaults with one warning; an unavailable pref
  dir gives session-only settings. An in-range hand edit off the step grid
  snaps rather than discarding the file.
- An audio setting is stored only after its command succeeds. A video
  change that fails reverts that field so the menu shows reality.
- Saves run only on explicit request (leaving settings dirty, reset, rebind
  commit) and at shutdown, never per frame. The payload is tiny and fixed,
  so the write is a cold main-thread action; it is not a scaling workload
  (`.claude/rules/threading.md`).
- App identity: one human org string and the existing app name name the
  pref path (SDL requires they never change once shipped); the packaged
  bundle id derives from them, with an explicit `-Dbundle-id` still winning.
- Provides: the store and file chain for 44 (bindings), 60 (zoom), 67A
  (scancodes), 70B (scene resolution); user-storage for 46 and 66A;
  `toggle` and `choice` widgets.
- VoidLight reference: load settings before window creation and the
  `SDL_GetPrefPath("HammerForgedGames", app)` org
  (`GameEngine.cpp:103-120`, `:590-599`); not its singleton, string-keyed
  variants, callbacks, install-dir JSON, or non-atomic write.

### Checklist

- [ ] Org name build option and app-identity validation (character sets
      shared with 52B's app-name check), with tests; 52B's bundle-id default
      derives from it.
- [ ] Platform wrappers: pref path, fullscreen toggle, clear minimum size,
      fullscreen flag composition (pure test).
- [ ] User-storage owner with `tmpDir` tests: atomic replace leaves no temp
      file, backup replaces an older backup, oversized read rejected,
      unavailable dir reported.
- [ ] Pure settings-file module: round-trip, omitted sections default,
      unknown field / bad enum / out-of-range / version 0 / future version
      rejected, off-grid percent snaps, version probe tolerates unknowns.
- [ ] Settings types, defaults from `AppConfig`, effective startup config,
      dirty tracking, pending video, reset, mute semantics; failed audio
      command leaves the value unchanged.
- [ ] Engine applies settings before window/audio/renderer, applies pending
      changes after transitions, saves on request and at shutdown;
      `RuntimeAudioSettings` threading removed. Renderer present-mode /
      frames-in-flight / resolution-policy facades are thin and covered by
      gpu-smoke and manual checks.
- [ ] `toggle` and `choice` widgets with wrap/skip-disabled tests.
- [ ] Settings screen rebuilt (audio, video, accessibility, reset with
      confirm, save-status line); pause menu gains Settings and Quit to Main
      Menu; keyboard and gamepad tests; Back saves only when dirty.
- [ ] UI-scale wiring through labels and layout; layout-fit tests at every
      UI scale.
- [ ] Docs: `docs/architecture.md` settings layer, pref path, apply order,
      user storage; `docs/state-stack-and-input.md` settings and pause
      menus; `docs/development-workflow.md` org option, identity table,
      settings locations, reset; Table T2 v1; `src/tests.zig`.
- [ ] Add the settings-field append rule to `.claude/rules/input-state.md`
      when this lands.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] Manual: every setting survives a restart; a hand-corrupted file gives
      defaults, one warning, and a backup; an unwritable pref dir gives
      session-only settings with a warning.
- [ ] Manual (Linux; Windows/macOS when available): fullscreen, present
      mode, frames in flight, and scale mode apply live.
- [ ] An interrupted write never leaves a truncated settings file (atomic
      replace plus the `tmpDir` test).
