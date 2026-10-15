## Slice 40: Action And Interaction Intent Substrate

**Status: complete (archived).** Depends on Slice 32 for a stable locomotion
intent path (landed). AI action emission remains a documented future extension
— not half-wired in 40. First real consumer is Slice 45 (destructibles).

Goal: add a **parallel, typed action-intent stream** for non-locomotion
gameplay (attack, interact, use, signal) so emergent systems can express more
than movement without overloading `NavigationIntent` or inventing a string
pub/sub bus.

### Problem (pre-slice)

- `SimulationIntent` was movement-only
  (`union(enum) { movement: MovementIntent }`).
- `NavigationIntent` is the high-level AI → steering handoff for **where to
  go**. Cramming "attack target X" into goal XY or priority bits would lock
  combat into pathfinding and break expandability.
- Architecture already described domain controllers for combat/rules/spawning
  (`architecture.md`) but no intent substrate existed for their outputs.

### What landed

- `ActionKind` / `ActionIntent` (scalar/enum only) and
  `action_intents: RangeOutputStream(ActionIntent)` on `SimulationFrame`.
- Producers write **only** to the specialized `action_intents` stream.
  `SimulationIntent` stays movement-only (`union(enum){ movement }`) — no
  dual-write into `intents` and no dead `action` union arm on the hot
  movement-intent stream.
- Fixed capacity `action_intent_live_capacity` (64); dual-axis warm
  `reserveActionIntents(cap, cap)` (one range per sequential append, like
  stimuli); `appendActionIntent` / `tryAppendActionIntent`.
- Pipeline: `action_intent_capture` is a **contract-only** stage (real appends
  run in `main_thread_inputs` before `update`); `action_react` stub counts
  merged intents — no DataSystem/world mutation.
- Player **R** / left shoulder rising-edge → `.interact` via
  `captureActionIntent` (latch advances only on successful append; soft-drop
  retries while held).
- Tests: multi-append FailingAllocator after dual-axis reserve, multi-range
  merge order, payload purity, capacity drop, dual-write guard
  (`intents` empty), stub count 0/1, rising-edge + soft-drop latch, capture →
  `pipeline.update` → `action_intents_consumed`.

### Architecture notes

- Consumers: domain controllers at explicit reaction phases after merge — not
  the pathfinder.
- Structural mutations from successful actions still go through deferred
  structural commands / world edits — action intents request consideration,
  they do not mutate `DataSystem` inside worker ranges.
- **AI expansion path (not implemented in 40):** arbitration may later emit
  actions when a pursue agent is in range — separate slice/checklist; must not
  overload `NavigationIntent`.

### Checklist

- [x] Define `ActionIntent` + kind enum + stream on `SimulationFrame`; reserve
      API; stats counters; docs for when to use action vs navigation vs domain
      events.
- [x] Pipeline phase: declare producer stage(s) and consumer reaction point(s)
      in `stage_order` / contracts without breaking existing stage resources.
- [x] Player or test harness emits at least one action kind end-to-end
      (e.g. interact-noop or attack-request that a stub consumer counts).
- [x] Capacity, deterministic multi-range merge order (serial stream contract),
      payload purity tests (no pointers/handles). Threaded multi-producer
      parity is deferred until a threaded action emitter exists (future AI
      slice) — same model as the stimuli sequential-append bus.
- [x] Document expansion path: AI arbitration may later emit actions when a
      pursue agent is in range — separate checklist item / future slice, not a
      silent partial in 40's "done" claim unless fully tested.

### Acceptance checks

- [x] Movement-only demos unchanged when no action producers run.
- [x] Action stream is deterministic and allocation-free after reserve.
- [x] NavigationIntent contract untouched.
- [x] `zig build verify` passes.


