## Slice 57B: Inventory And Equipment UI

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md), [Slice 53B](slice-53b.md), [Slice 57](slice-57.md), [Slice 49](slice-49.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 53B (widgets, modal routing), 53A (text
labels), 57 (items, inventory stage, pickup events), and 49 (determinism
harness). Slice 63 reuses its player action queue, live modal overlay, and
toast.

Goal: a player-facing inventory and equipment panel, a coins readout, and
pickup toasts. Use, equip, unequip, and drop reach gameplay only as action
intents, so UI code never mutates simulation state and every UI-originated
action is deterministic step input.

### Current foundation

- `src/app/state.zig` `state_policy` presets (`modal_overlay`,
  `pass_through_overlay`, `opaque_screen`): none keeps gameplay updating
  below while routing input to a modal.
- `ActionKind` (`simulation.zig`) has `interact`, `attack`, `use`, `signal`;
  no `drop` or `unequip`.
- Every `ActionIntent` today derives from `InputState` in
  `main_thread_inputs`.
- From Slice 57 (not landed): catalog names and icons, `.use` with an item,
  the inventory stage, `item_picked_up` events, one world-item template helper.

### Architecture notes

- A live modal overlay preset: gameplay keeps updating and rendering below,
  input routes to the modal, held gameplay input is released
  (`.claude/rules/input-state.md`).
- The panel reads only const gameplay views and writes only to a pending
  player-action queue; its signatures prove it, checked at comptime.
- Pending player actions drain into `action_intents` in input capture, in
  order, under a fixed per-step count with at most one drop per step; the
  rest wait in order and nothing is shown as sent before it is queued.
- `drop` and `unequip` kinds land only with this producer (no dead tags).
  Drops create world items through Slice 57's helper and its per-step create
  budget; an unequip with no free slot is refused and counted (inventory
  space, not storage capacity).
- Panel labels re-text only when the player's inventory changes, never per
  frame (`.claude/rules/render.md` § Text).
- Toasts are presentation-only: a fixed pool, frame-count timed, fed from
  pickup events; they never read or write simulation state.
- VoidLight: port the grid-plus-gear layout; do not port string IDs,
  per-refresh formatted labels, or UI calling mutation paths directly.

### Checklist

- [ ] Inventory panel and coins readout on 53B with 53A labels, re-texted
      only on inventory change.
- [ ] Live modal overlay preset.
- [ ] Pending player-action queue drained in input capture (ordered, one drop
      per step).
- [ ] `drop` / `unequip` kinds with inventory-stage handling and tests.
- [ ] Toast HUD primitive and pickup toasts.
- [ ] (added by Slice 67) Strings as `StringId`s if this lands after 67E.
- [ ] Docs: `docs/state-stack-and-input.md` (preset, queue),
      `docs/architecture.md` (UI → gameplay boundary).
- [ ] Add the read-only UI panel signature rule to `.claude/rules/render.md`
      when this lands.

### Acceptance checks

- [ ] Equip, unequip, use, and drop round-trip through `action_intents` and
      keep Slice 57's inventory invariants.
- [ ] The comptime signature check passes for every panel entry point.
- [ ] Two drops queued in one frame create one world item this step and one
      the next.
- [ ] A scripted session with panel use, equip, and drop gives the same
      per-step `simulationChecksum()` trace serial and threaded (49's
      harness).
- [ ] No re-text while the panel is open and unchanged.
- [ ] `zig build gpu-smoke` (display-gated) shows the panel; `zig build verify`
      passes.
