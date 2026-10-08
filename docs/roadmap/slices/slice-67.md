## Slice 67: UI, Input, And Text Completion

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md), [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md), [Slice 46](slice-46.md), [Slice 60](slice-60.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella).** Closes when 67A, 67B, 67C, and 67E are
archived. Full localization (formerly 67D) is
[Deferred By Owner](../../framework-implementation-slices.md#deferred-by-owner),
not a sub-slice.

Goal: finish the shipping UI, input, and text surface on the 53A/53B/54/44/46
foundation (mouse and menu repeat, one text pipeline, an event log, UI
sound, save-slot presentation, and localization roots) so no item of the UI,
text, settings, and saves backlog remains.

| Sub-slice | Outcome | Hard prerequisites |
| --- | --- | --- |
| [**67A**](slice-67a.md) | Pointer input and HUD tooltips, gamepad menu hold-to-repeat, physical-key (scancode) bindings with a one-time settings migration | 53B, 54, 44 |
| [**67B**](slice-67b.md) | Debug overlays on labels and the old text path deleted, HUD event log, text-atlas telemetry, UI navigation sound | 53A, 53B, 44 |
| [**67C**](slice-67c.md) | World-only save thumbnails, a header-only save format bump with slot names, a text-input widget with IME | 46, 60, 67A |
| [**67E**](slice-67e.md) | Localization roots: stable string IDs, a compiled-in English table, every existing UI string migrated byte-identical | 53B (merged order: after 67C) |

### Architecture notes

- No simulation surface: 67 adds no stage, pipeline resource, component tag,
  seed domain, or persistent `DataSystem`/`WorldSystem` field, and never
  changes the replay format or checksum. Input resolves to `Action` before
  the recorder sees it; UI-originated gameplay requests stay with Slice
  57B's queue (`.claude/rules/simulation.md`).
- Debug overlays and the event log are read-only over simulation
  (`.claude/rules/engine-design.md`).
- Main thread only, except Slice 46's existing lane jobs for save write and
  slot scan (`.claude/rules/threading.md`).
- SDL calls live in `src/platform/` wrappers called from `src/app/`; GPU
  work stays behind `Renderer` facades; `src/game/ui/` consumes only typed
  per-event context that `Engine` resolves once
  (`.claude/rules/engine-design.md`, `.claude/rules/render.md`).
- Per-event and per-frame paths are allocation-free; each sub-slice lists
  its `FailingAllocator` proofs (`.claude/rules/memory-performance.md`).
- Later slices that add user-facing text, an event arm, or a keyboard
  default carry the matching item in their own Checklist (log line or
  explicit none per 67B, `StringId` per 67E, scancode default per 67A).

### Checklist

- [ ] 67A, 67B, 67C, 67E archived.
- [ ] Add the event-log line and action-name `StringId` coverage rule to
      `.claude/rules/render.md` when this lands.

### Acceptance checks

- [ ] Each sub-slice's Acceptance checks pass.
