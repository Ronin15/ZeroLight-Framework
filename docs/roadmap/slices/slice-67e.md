## Slice 67E: Localization Roots

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Hard prerequisite: Slice 53B (`UiScreen` widget
text and hint columns). In the merged order it lands after Slice 67C, so one
change migrates the UI literals of 53B, 54, 44, 46, and 67A–67C. It may land
earlier, any time after 53B: it then migrates whatever UI text exists at
landing, and every later slice uses `StringId`s from day one. It is preferred
before Slice 56. If any of 56–63 land first, 67E also migrates their UI and
event-log strings in the same change, extending its Inventory. Every slice
that adds UI text after 67E uses `StringId`s from day one (Slice 67 rule; see
the ledger in [Slice 67](slice-67.md)). It adds no simulation surface (see the
shared 67 contracts) and no settings field or schema version.

This is the root of localization only: the pieces that are costly to
retrofit (string identity at every call site and one argument convention).
Full localization (per-locale tables, a locale setting, plurals, pseudo-locale,
coverage lints, and per-locale fonts) is deferred by the owner:
[Deferred By Owner → Full localization](../../framework-implementation-slices.md#deferred-by-owner).
Nothing here builds a hook for it beyond the accessor bodies it will replace.

Goal:
- **IDs:** every user-facing UI string is named by a stable symbolic
  `StringId` in one comptime enum.
- **Data:** one built-in English table, compiled in, validated at comptime.
- **Access:** `text(id)` for fixed strings and an English-only fixed-buffer
  `format(id, args, out)` for value-bearing strings. No allocation, never per
  frame.
- **Migration:** every existing hard-coded menu and widget string goes
  through an ID, and the English output is byte-identical.
- **Rule:** new UI-facing text in later slices uses `StringId` (a written
  coding-standards rule, not a lint). Debug overlays stay English.

### Current foundation (do not rebuild)

- Hard-coded strings today:
  - `src/game/main_menu_state.zig:37-41` ("Start Game", "Settings", "Quit")
    and `:191` (title "Zig SDL3 GPU")
  - `src/game/settings_menu_state.zig:58-63`, `:220-230` (volume rows with
    inline `bufPrint` formats, "Back", "Settings")
  - `src/game/pause_state.zig:33` (prompt literal)
  - `src/game/loading_state.zig:217-227` ("Loading", "Building world",
    "Starting", "Failed to load — Esc to return")

  53B/54/44/46/67A–67C replace these screens and add their own literals
  (whichever have landed when 67E lands):
  - 53B: widget `text` and static `hint: []const u8`
  - 54: `choice` option tables `[]const []const u8`
  - 44: Controls action names and prompt footers
  - 46: slot button text
  - 67A: tooltip hints
  - 67B: event-log format strings
  - 67C: name dialog
- `src/assets/manifest.zig:7-18`: the comptime enum + table pattern for stable
  IDs (`SpriteAssetId`, `AudioAssetId`) and the coverage test (`:191-207`).
- 53B: `k_widget_text_capacity = 128`, `setText` truncating on a UTF-8
  code-point boundary, and the fake label backend used by screen tests.
- VoidLight has no localization system; nothing to port.

### Architecture notes

**Files and owners:**

| File | Layer | Contents |
| --- | --- | --- |
| `src/assets/strings.zig` | assets | `StringId`, `StringSpec`, the comptime English table `string_specs`, its comptime validation, `text`, `format`, `StringArg`, `FormattedText`. Pure: no I/O, no logging, no allocation. |
| `src/game/ui/action_names.zig` | game | `actionNameId(Action) ?StringId` (only when Slice 44's Controls screen exists at landing) |

**English table: compiled-in Zig, not `en.zon`.** English is the
always-present fallback with no file read or startup-failure path, so a later
per-locale loader only adds runtime tables beside it and swaps the bodies of
`text`/`format`, without moving English data or touching a call site.

**String IDs:**

- `pub const StringId = enum(u16) { … }` is hand-written. Tag names are the
  stable keys. Numeric values are build-local: no `StringId` is ever
  persisted in saves or settings.
- Naming is `<screen>_<item>`, with `common_*` for shared words and
  `action_<name>` for rebindable actions.
- **Spec table.** `StringSpec { en: []const u8, args: u3 = 0 }`.
  `string_specs` is `std.enums.EnumArray(StringId, StringSpec).init(.{ … })`,
  so a tag without an English entry does not compile.
- **Comptime validation** (a `comptime` block in `strings.zig`; any violation
  is a `@compileError` naming the ID). For every ID:
  - `en` is non-empty, valid UTF-8, has no C0 control except `\n`, and no DEL
  - `en.len` ≤ `k_max_string_bytes = 256` (53A's label cap)
  - `args` ≤ `k_max_string_args = 4`
  - braces are balanced; `{{` and `}}` are literal braces
  - every placeholder `{N}` has `N < args`, and every index below `args`
    appears at least once

**Accessors** (main thread, cold or change-driven; no allocation, no logging):

- `pub fn text(id: StringId) []const u8` returns the English text. It asserts
  `string_specs.get(id).args == 0`.
- `pub fn format(id: StringId, args: []const StringArg, out: []u8)
  FormattedText` with `FormattedText { text: []const u8, truncated: bool }`
  and `StringArg = union(enum) { int: i64, text: []const u8 }`:
  1. Assert `args.len == spec.args`.
  2. Expand `{0}`–`{3}` into `out`. A placeholder may repeat and appear in any
     order. Integers print in plain decimal with a `-` sign and no grouping.
     There are no float args: callers pre-format dates and playtimes into
     locale-neutral `text` args (`YYYY-MM-DD HH:MM`, `H:MM:SS`).
  3. On overflow, truncate on a UTF-8 code-point boundary and set
     `truncated`.
  - English only: it reads `spec.en`.
- **Argument convention (the only rule 67E fixes for value-bearing text).**
  A string that shows a runtime value is one ID whose English text carries
  `{N}` placeholders, rendered only through `format`. Call sites never
  concatenate an ID's text with a value or build a sentence from fragments.
  No 67E-era string chooses its wording by count ("Destroyed {0}", never a
  singular/plural branch). Count-dependent forms belong to the deferred full
  localization and would resolve inside `format`, so call sites never change.
- **When formatting happens.** Only when the value changes, through owners'
  existing dirty compares. Never per frame.

**UI routing (53B amendments made by this slice):**

- **Widget columns.**
  - New `text_id: ?StringId` for static text. `build()` copies
    `text(id)` into the widget's `text` buffer once (53B's `setText`
    truncation).
  - `hint: []const u8` becomes `hint: ?StringId`. 67A's build-time
    `UiTooltipTooLong` check stays and measures the resolved English text.
  - 54's `choice` option table becomes `[]const StringId`.
  - Declarations use `.text_id = .main_menu_start` instead of literals.
- **Dynamic text.** Owners call `strings.format(id, args, &buf)` and then
  `setText(w, result.text)` when the value changes. Examples: HUD level and
  destroyed count, slider value `common_value_percent`, 44 prompt footers,
  46/67C slot rows, 67C name dialog title, and 67B's event-log lines (the
  repeat suffix is `event_log_repeat_suffix`).
- **Action names.** 44's Controls rows use `actionNameId(action)`, an
  exhaustive switch that returns `null` for non-rebindable actions, so a
  later `Action` cannot compile without a name decision.
- **Stays unlocalized:** key and gamepad button labels (SDL key names, vendor
  button tables), the OS window title, and **debug tooling**
  (`FpsCounter`, `AiDebugOverlay`), which stays English.

**Inventory: every ID this slice lands, with its English text** (rows for
screens that have not landed when 67E lands are dropped; each listed English
string is carried verbatim from the landed literal, and where this table and
a landed literal differ, the landed literal wins so output stays
byte-identical):

| Group | IDs (`args`) → English |
| --- | --- |
| common | `common_back` "Back"; `common_cancel` "Cancel"; `common_confirm` "Confirm"; `common_on` "On"; `common_off` "Off"; `common_value_percent` (1) "{0}%"; `common_prompt_select_back` (2) "{0}: Select  {1}: Back"; `confirm_unsaved_progress` "Unsaved progress will be lost." |
| main menu | `main_menu_title` "Zig SDL3 GPU"; `main_menu_start` "Start Game"; `main_menu_load` "Load Game"; `main_menu_settings` "Settings"; `main_menu_quit` "Quit"; `quit_confirm_title` "Quit Game?" |
| pause | `pause_title` "Paused"; `pause_resume` "Resume"; `pause_save` "Save Game"; `pause_load` "Load Game"; `pause_settings` "Settings"; `pause_quit_to_menu` "Quit to Main Menu"; `pause_quit_game` "Quit Game"; `quit_to_menu_confirm_title` "Quit to Main Menu?" |
| settings (54) | `settings_title` "Settings"; `settings_section_audio` "Audio"; `settings_master_volume` "Master Volume"; `settings_sfx_volume` "SFX Volume"; `settings_music_volume` "Music Volume"; `settings_mute` "Mute"; `settings_section_video` "Video"; `settings_window_mode` "Window Mode"; `window_mode_windowed` "Windowed"; `window_mode_borderless` "Borderless Fullscreen"; `settings_present_mode` "Present Mode"; `present_mode_vsync` "VSync"; `present_mode_mailbox` "Mailbox"; `present_mode_immediate` "Immediate"; `settings_frames_in_flight` "Frames in Flight"; `settings_scale_mode` "Scale Mode"; `scale_mode_fit` "Fit"; `scale_mode_integer` "Integer"; `scale_mode_stretch` "Stretch"; `scale_mode_overscan` "Overscan"; `settings_section_accessibility` "Accessibility"; `settings_ui_scale` "UI Scale"; `settings_controls` "Controls"; `settings_reset` "Reset to Defaults"; `settings_reset_confirm` "Reset all settings to defaults?"; `settings_save_failed` "Settings could not be saved" |
| controls (44) | `controls_title` "Controls"; `controls_column_action` "Action"; `controls_column_keyboard` "Keyboard"; `controls_column_gamepad` "Gamepad"; `controls_reset` "Reset Controls"; `controls_reset_confirm` "Reset all controls to defaults?"; `controls_capture_keyboard` (1) "Press a key for {0}"; `controls_capture_gamepad` (1) "Press a button for {0}"; `controls_conflict` (2) "{0} is already bound to {1}"; `controls_protected` (1) "{0} needs at least one binding"; `controls_unbound` "—"; one `action_<name>` per rebindable `Action`: "Move Left", "Move Right", "Move Up", "Move Down", "Pause", "Confirm / Resume", "Back / Quit", "Menu Up", "Menu Down", "Menu Left", "Menu Right", "Dig Hole", "Dig Ramp", "Dig Down", "Interact" |
| loading | `loading_title` "Loading"; `loading_building_world` "Building world"; `loading_starting` "Starting"; `loading_failed` "Failed to load — Esc to return" |
| HUD (53B/67A) | `hud_level` (1) "Level {0}"; `hud_destroyed` (1) "Destroyed {0}"; `hud_depth_gauge_hint` "Depth: current level / deepest level"; `hud_portrait_hint` "Player" |
| event log (67B) | `event_obstacle_destroyed` (1) "Obstacle destroyed (level {0})"; `event_reached_level` (1) "Reached level {0}"; `event_log_repeat_suffix` (1) " (x{0})" |
| save/load (46/67C) | `save_menu_title` "Save Game"; `load_menu_title` "Load Game"; `save_slot_unnamed` (1) "Slot {0}"; `save_slot_empty` (1) "Slot {0} — Empty"; `save_slot_incompatible` (1) "Slot {0} — Incompatible version"; `save_slot_corrupt` (1) "Slot {0} — Corrupt"; `save_slot_row` (4) "{0} — Level {1} — {2} — {3}"; `save_default_name` (1) "Save {0}"; `save_name_title` (1) "Save to Slot {0}"; `save_overwrite_title` (1) "Overwrite {0}?"; `save_name_confirm` "Save"; `save_status_saving` "Saving…"; `save_status_saved` "Saved"; `save_status_failed` "Save failed"; `load_failed` "Could not load save" |
| hints | one `<screen>_<widget>_hint` ID per widget hint authored in 53B/54/44/46/67C, with the English copy carried over verbatim from those slices' landed literals. The landing change replaces this row with the enumerated list (ID → English text) |

**Fixed budgets** (constants; none derived from content size):

- `k_max_string_args = 4`
- `k_max_string_bytes = 256`

**Errors.** `text` and `format` are infallible (overflow truncates). Spec
errors are compile errors. `UiBuildError` is unchanged.

**Threading and allocation.** Main thread only. `text` and `format` take no
allocator and allocate nothing; the English table is static data.

**Diagnostics.** None at runtime: the module is pure and log-free.

### Checklist

- [ ] `src/assets/strings.zig`: `StringId` (the Inventory as landed),
      `StringSpec`, `string_specs`, the comptime validation block, `text`,
      `format`, `StringArg`, `FormattedText`. Tests:
      - a runtime walk of every `StringId` mirroring the comptime checks
        (non-empty, valid UTF-8, ≤ 256 bytes, placeholders consistent with
        `args`)
      - `format`: reordered `{1} {0}`, repeated placeholder, `{{` / `}}`,
        int and text args, negative int, truncation on a code-point boundary
        with `truncated` set, exact-fit output with `truncated` clear
- [ ] 53B toolkit amendments: `text_id`, `hint: ?StringId`, `choice` options
      as `[]const StringId`; `build()` resolves `text_id` once. Fake label
      backend tests: a `text_id` widget shows `text(id)`; a hint resolves
      through its ID; 67A's `UiTooltipTooLong` still fires on an over-cap
      English hint (if 67A has landed).
- [ ] Migrate every screen present at landing: main menu, settings, pause,
      confirm dialogs, loading, HUD, Controls + capture + prompts
      (`actionNameId`), Save/Load + name dialog, event-log feed. Each
      screen's existing tests are ported to assert the resolved English text
      is byte-identical to the pre-67E literal.
- [ ] Inventory `hints` row replaced by the enumerated hint IDs.
- [ ] `FailingAllocator` proof: a warmed migrated screen's dynamic-text
      update (`format` → `setText`, e.g. HUD level and destroyed count) runs
      under a `std.testing.FailingAllocator` with `fail_index` at the
      post-warmup count and allocates zero times.
- [ ] Docs:
      - `docs/architecture.md`: a short Localization section covering
        `strings.zig` ownership, the compiled-in English table, the argument
        convention, what stays unlocalized, and a link to the deferred full
        localization entry
      - `docs/coding-standards.md`: the written UI text rule (user-facing UI
        text uses `StringId`, value-bearing text goes through `format`,
        debug tooling stays English; no lint enforces it)
      - `docs/development-workflow.md`: adding a string
      - `docs/state-stack-and-input.md`: screens declare `text_id`s
      - `src/tests.zig` registrations

### Acceptance checks

- [ ] `zig build verify` passes. No user-facing literal remains in the
      migrated screens outside tests, debug overlays, and the unlocalized
      categories above.
- [ ] English output is byte-identical to the pre-67E screens (ported screen
      tests).
- [ ] Review check: no `StringId` is persisted in saves or settings; no
      formatting runs per frame; `strings.zig` performs no I/O, logging, or
      allocation; no settings field or schema version was added.

---
