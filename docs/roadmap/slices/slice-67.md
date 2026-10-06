## Slice 67: UI, Input, And Text Completion

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella).** Four sub-slices; each has its own Status,
Checklist, and Acceptance checks. **67A** and **67B** land after their
prerequisites in the table (the merged order places both after Slice 46).
**67C** lands after Slices 46, 60, and 67A. **67E** (localization roots)
needs only 53B and lands after 67C in the merged order. Full localization
(per-locale tables, locale setting, plurals, pseudo-locale, coverage lints,
and per-locale/CJK font subsets, formerly 67D) is not a 67 sub-slice: it is
[Deferred By Owner → Full localization](../../framework-implementation-slices.md#deferred-by-owner).
Together they promote every remaining item of the *UI, text, settings, and
saves (53A, 53B, 54, 44, 46)* backlog block. When 67 lands, nothing from that
block is left in Scaling Gaps.

| Sub-slice | Scope | Hard prerequisites |
| --- | --- | --- |
| **67A** | Pointer input (hover = focus, click, slider drag, wheel scroll), HUD hover tooltips, gamepad D-pad and left-stick menu hold-to-repeat, scancode keyboard bindings with a settings schema bump (relative; v4 in the merged order) and a keymap-ready keycode→scancode migration | 53B, 54, 44 |
| **67B** | FPS and AI debug overlays moved onto `TextLabelSystem`, then the `PreparedText` / `TextEntrySlot` / `TTF_RenderText_Blended` path deleted; HUD event log; text-atlas telemetry plus a Western-corpus page probe; UI navigation SFX | 53A, 53B, 44 |
| **67C** | Save slot presentation: world-only GPU thumbnail capture, a header-only save `format_version` bump (relative; v2 in the merged order: thumbnail section plus slot name), slot-list thumbnails, `text_field` widget with IME composition and the `SDL_StartTextInput` lifecycle | 46, 60, 67A |
| **67E** | Localization roots: comptime `StringId` registry with per-ID arg counts, one compiled-in English table, `text(id)` and an English-only fixed-buffer `format(id, args, out)`, every existing UI string migrated (byte-identical English), a written (not linted) UI text rule; no settings field or version | 53B (merged order: after 67C) |

**Contracts shared by every 67 sub-slice (settled):**

- **No simulation surface.** 67 adds no `StageId`, `PipelineResource`,
  `stage_order` entry, `Component` tag, `SeedDomain`, or persistent
  `DataSystem` / `WorldSystem` field. Slice 49's checksum completeness lists,
  64B's `checksum_*_fields` classification, and `checksum_format_tag` do not
  change. The replay format does not change:
  bindings are resolved to `Action` bits before Slice 49's recorder sees them,
  and no 67 UI path writes simulation state. UI-originated gameplay requests
  stay with Slice 57B's `PendingPlayerActions`.
- **Main thread only.** Pointer, text input, menu repeat, labels, the event
  log, UI sounds, and thumbnail capture/readback all run on the main thread.
  The only off-thread work is Slice 46's background-lane save write and slot
  scan. 67C hands those jobs bigger immutable buffers but adds no new job kind.
- **Ownership.**
  - SDL calls (`SDL_StartTextInput`, cursor show/hide, hints, scancode
    lookups) live in `src/platform/sdl.zig` wrappers that `src/app/` calls.
  - GPU work (thumbnail pass, download, fence) is render-internal behind
    `Renderer` facades.
  - `src/game/ui/` stays free of SDL handles. It consumes typed
    `EventContext` fields that Engine resolves once per event, the same way
    53B resolves `press`.
- **`EventContext` final shape** (53B base, 44 `device`, plus 67 fields; all
  67 fields default so existing constructions compile):

  ```zig
  pub const EventContext = struct {
      transitions: *StateTransitions,
      press: ?ActionPress = null,            // 53B (44 resolves via RuntimeInputBindings)
      device: InputDevice = .keyboard,       // 44; 67A adds the .pointer tag
      pointer: ?PointerEvent = null,         // 67A
      timestamp_ns: u64 = 0,                 // 67A: event.common.timestamp (SDL_GetTicksNS clock)
      text: ?TextEdit = null,                // 67C
      keyboard_event: bool = false,          // 67C: event is SDL_EVENT_KEY_DOWN / KEY_UP
  };
  ```

- **Allocation.** Every per-event and per-frame 67 path allocates nothing. UI
  state lives in fixed arrays inside `UiScreen` / `EventLog` /
  `MenuRepeat` / `TextInputController`. Each sub-slice ships its own
  `std.testing.FailingAllocator` proofs (listed in its Checklist).

### Cross-slice additions (folded into the owning slices)

| Owner | What landed there |
| --- | --- |
| [53A](slice-53a.md) | Debug overlays move in 67B; `ui_scale_percent` unclamped (67B probe up to 1800) |
| [53B](slice-53b.md) | Text input / pointer / tooltips / event log owned by 67A/67B/67C; VoidLight mouse line → 67A |
| [44](slice-44.md) | Scancodes are 67A (v4); `RebindCaptureState` repeat/stick-press rule (Checklist) |
| [46](slice-46.md) | No-thumbnail note → 67C header-only bump + `SaveNameDialogState`; `render_below = true` requirement |
| [54](slice-54.md) | Load freeze rule (`save_requested` after an upgrade) |
| [56](slice-56.md), [57](slice-57.md), [59](slice-59.md), [61](slice-61.md), [63](slice-63.md) | Event-log feed arms per 67B (Checklist); 63's stats/event-log consumer text |
| [56](slice-56.md), [56B](slice-56b.md), [57](slice-57.md), [57B](slice-57b.md), [59](slice-59.md), [60](slice-60.md), [61](slice-61.md), [62](slice-62.md), [63](slice-63.md) | `StringId` / English `StringSpec` / `strings.format` item when landing after 67E |
| [56](slice-56.md), [57](slice-57.md), [69C](slice-69c.md) | Keyboard defaults are `SDL_SCANCODE_*` after 67A |
| [67A](slice-67a.md) | `UiTooltipTooLong` kept by 67E (measures the resolved English hint) |
| [70B](slice-70b.md) | 67C gpu-smoke thumbnail probe per `scene_resolution` mode |

Standing rules for every later slice: a new `SimulationEventPayload` arm adds
its `event_log_feed.lineFor` line or `=> null` in the same change; a new
`Action` adds its `action_<name>` `StringId` through `actionNameId`.
