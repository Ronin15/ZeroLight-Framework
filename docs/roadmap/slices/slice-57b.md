## Slice 57B: Inventory And Equipment UI

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md), [Slice 53B](slice-53b.md), [Slice 57](slice-57.md), [Slice 49](slice-49.md), [Slice 64C](slice-64c.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 53B (UI toolkit), Slice 53A (text
labels), Slice 57, Slice 49 (replay format), and Slice 64C (replay v2 header;
this slice takes the next version). Slice 63 reuses the
`PendingPlayerActions` queue, the `live_modal_overlay` preset, and the toast
primitive this slice lands.

Goal: a player-facing inventory/equipment panel, a coins HUD readout, and
pickup toasts. Use, equip, unequip, and drop are issued through
`action_intents`, so UI code never mutates gameplay state directly, and every
UI-originated intent is replayable.

### Current foundation

- From Slice 57: catalog names and `grim_items` icon entries, `.use` with
  `ActionIntent.item`, `InventoryController`, `item_picked_up` events, the
  world-item cap rule.
- From Slice 53B: widgets, layout, and modal-state routing. From Slice 53A:
  `TextLabelId` label ownership and idle-reclaim rules (`docs/architecture.md`
  render-service rules, `docs/state-stack-and-input.md`).
- From Slice 49: `ReplayInputFrame` and the recorder/verifier.

### Architecture notes

- **Overlay policy.** The panel uses a new preset defined in this slice:
  `state_policy.live_modal_overlay = { update_below = true, events_below =
  false, render_below = true, input_routing = modalUi(), blocks_held_gameplay_input
  = true }`. Gameplay keeps simulating underneath; held gameplay input is
  blocked.
- **Read-only panel API.** The panel's render and input entry points take only
  `*const DataSystem`, `*const ItemCatalog`, and a borrowed
  `*PendingPlayerActions`. It owns no gameplay state and has no path to a
  mutable `DataSystem`. A comptime test asserts those parameter types, so the
  panel's lack of direct writes is checked by signature, not by review alone.
- **`PendingPlayerActions`.** Requests flow through a fixed FIFO of 8
  `ActionIntent`s (`pending_player_action_capacity = 8`) owned by
  `GameDemoState`. `pipeline.capturePendingPlayerActions` drains it in
  `main_thread_inputs` through `tryAppendActionIntent`. On a soft-drop it stops
  and keeps the rest. It also stops before a second `.drop` in the same step,
  so at most one UI drop create happens per step (the rest stay queued, in
  order). A full FIFO refuses the UI request (counted); the UI shows nothing
  as "sent" until the push succeeds.
- **Replay of UI-originated intents.** This slice is the first producer of
  `ActionIntent`s that are not derived from `InputState`. It bumps
  `replay_format_version` to the live value + 1 (v3 after Slice 64C's v2). Each frame gains `player_action_count: u8`
  followed by that many `ReplayActionRecord`s, bounded by
  `pending_player_action_capacity`. A record mirrors every scalar
  `ActionIntent` field present at landing (kind, target index + generation,
  cell, level, `has_cell`, item). The verifier re-enqueues the records into
  `PendingPlayerActions` before `replayStep`. Slice 63 extends the record
  with its new `ActionIntent` fields (quantity, `price_limit`) and a format
  bump.
- Append `ActionKind.drop` and `ActionKind.unequip` only together with this
  producer, so no dead tags ship.
- `InventoryController` handlers:
  - Drop creates a world item at the holder's feet through
    `worldItemTemplate`, under the Slice 57 cap rule.
    `world_item_creates_per_step_max` grows by 1 (comptime asserts still
    hold).
  - Unequip moves the item to the first empty slot, or is refused and
    counted.
- `InventoryController` bumps an `inventory_version: u32` (wrapping) whenever
  the player's inventory changes. Panel labels are 53A `TextLabelId`s;
  `setText` runs only when `inventory_version` changes, never per frame.
- **Toasts.** A `toast` HUD primitive on 53B: fixed 4 slots, timed by frame
  count on the presentation side (it never reads or writes simulation state).
  Pickup toasts come from `item_picked_up` events involving the player.

### Checklist

- [ ] Panel and coins HUD on Slice 53B, with labels as 53A `TextLabelId`s
      updated only on `inventory_version` change.
- [ ] `live_modal_overlay` preset in `state_policy`.
- [ ] `PendingPlayerActions` + `capturePendingPlayerActions` (soft-drop stop,
      one drop per step, counted refusal).
- [ ] Replay format v3 (live value + 1): `player_action_count` +
      `ReplayActionRecord`s, recorder and verifier re-enqueue, version bump
      and decode tests.
- [ ] (added by Slice 64) The format bump is **relative**: set `replay_format_version` to the
      live value + 1 in the same change, and keep every earlier header and
      frame extension (64C's 80-byte header and `build_fingerprint`, 64A's
      renamed flags bit0). The round-trip test decodes a file that exercises
      all earlier extensions plus the new records.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      Otherwise 67E migrates it.
- [ ] `drop` / `unequip` kinds with `InventoryController` handling and tests;
      `world_item_creates_per_step_max` +1.
- [ ] `toast` HUD primitive (fixed 4 slots, frame-count timing) and pickup
      toasts from `item_picked_up` events.
- [ ] Docs: `docs/state-stack-and-input.md` (preset, queue) and
      `docs/architecture.md` (UI → gameplay boundary, replay v3).
- [ ] Add the read-only UI panel signature rule to `.claude/rules/render.md`
      when this lands.
- [ ] Add the replay-record-mirrors-`ActionIntent` rule to
      `.claude/rules/simulation.md` when this lands.

### Acceptance checks

- [ ] Equip, unequip, use, and drop round-trip through `action_intents` and
      keep the Slice 57 inventory invariants.
- [ ] The comptime signature test passes: panel entry points accept only
      `*const DataSystem`, `*const ItemCatalog`, and `*PendingPlayerActions`.
- [ ] Two drops queued in one frame create one world item this step and one
      the next.
- [ ] A recorded session with panel use, equip, and drop replays to the same
      per-step `simulationChecksum()` trace (Slice 49 verifier, format v3).
- [ ] No `setText` calls while the panel is open and unchanged.
- [ ] `zig build gpu-smoke` (display-gated) shows the panel; `zig build verify`
      passes.

### VoidLight reference

- Port: the grid-plus-gear layout concept and the capacity readout
  (`InventoryController.cpp:268-670`).
- Do not port: string component IDs and per-refresh `std::format` labels
  (`:95-98,386-486,633`); UI that calls `edm` mutation paths directly.

