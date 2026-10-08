## Slice 67E: Localization Roots

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Merged order: after 67C, so one change migrates
the literals of 53B, 54, 44, 46, and 67A–67C; it may land any time after
53B and then migrates whatever UI text exists. Preferred before 56; if any of
56–63 land first, this slice migrates their UI and event-log strings too.

Goal: the parts of localization that are costly to retrofit, and nothing
more. Every user-facing UI string is named by a stable symbolic ID in one
comptime enum, backed by one compiled-in, comptime-validated English table;
fixed text and value-bearing text each have one accessor (value-bearing text
through placeholders and a fixed output buffer, never concatenation); every
existing menu and widget string is migrated with byte-identical English
output. Full localization is
[Deferred By Owner](../../framework-implementation-slices.md#deferred-by-owner);
nothing here builds for it beyond the accessor bodies it will replace.

### Current foundation

- Hard-coded UI strings live in `main_menu_state.zig` (items and the title),
  `settings_menu_state.zig` (rows with inline `bufPrint` formats),
  `pause_state.zig` (prompt), and `loading_state.zig` (phase lines). 53B,
  54, 44, 46, and 67A–67C replace these screens and add their own literals:
  widget text and hints, choice options, Controls action names and prompts,
  slot rows, tooltips, event-log lines, the name dialog.
- `src/assets/manifest.zig` is the comptime enum + table pattern for stable
  IDs with a coverage test.
- 53B truncates widget text on a UTF-8 boundary; 53A caps label length.
- VoidLight has no localization system.

### Architecture notes

- Owner scope (2026-10-05): roots only; no locale setting, no settings
  field or version, no per-locale data, no lint.
- English is compiled in, so it never fails to load and a later per-locale
  loader only adds tables beside it without touching a call site.
- String IDs are build-local: no ID is ever persisted in saves or settings
  (`.claude/rules/simulation.md` § Persistent data).
- A tag without English text, malformed placeholders, or text over the
  label cap fails the build.
- Value-bearing text is one ID with placeholders; no wording branches on a
  count (plural forms belong to the deferred work and resolve inside the
  accessor). Formatting runs only on value change, never per frame, and
  allocates nothing (`.claude/rules/memory-performance.md`).
- Controls action names come from an exhaustive switch, so a new `Action`
  cannot compile without a name decision.
- Stays unlocalized: key and button labels, the OS window title, and debug
  tooling (FPS and AI overlays).
- No simulation surface (Slice 67). Main thread; the strings module is
  pure (no I/O, logging, or allocation).

### Checklist

- [ ] `src/assets/strings.zig`: ID enum (the inventory as landed), English
      table, comptime validation, fixed and formatted accessors; tests
      mirroring the comptime checks at runtime and covering reordered and
      repeated placeholders, literal braces, int and text args, truncation
      on a code-point boundary, exact fit.
- [ ] Toolkit amendments: static text and hints by ID, choice options by
      ID, resolved once at build; 67A's over-long tooltip check measures the
      resolved English; fake-backend tests.
- [ ] Every screen present at landing migrated (menus, settings, pause,
      dialogs, loading, HUD, Controls and capture, Save/Load and name
      dialog, event-log feed); each screen's tests assert byte-identical
      English.
- [ ] Every authored widget hint enumerated as an ID with its landed
      English text.
- [ ] `FailingAllocator` proof: a warmed migrated screen's dynamic-text
      update allocates nothing.
- [ ] Docs: `docs/architecture.md` Localization section (ownership,
      compiled-in English, argument convention, what stays unlocalized,
      deferred link); `docs/development-workflow.md` adding a string;
      `docs/state-stack-and-input.md` screens declare string IDs;
      `src/tests.zig`.
- [ ] Add the UI text rule (user-facing text uses string IDs, value-bearing
      text goes through the formatter, debug tooling stays English) to
      `.claude/rules/render.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes; no user-facing literal remains in migrated
      screens outside tests, debug overlays, and the unlocalized categories.
- [ ] English output is byte-identical to the pre-67E screens.
- [ ] Review: no string ID is persisted; no formatting runs per frame; the
      strings module performs no I/O, logging, or allocation; no settings
      field or version was added.
