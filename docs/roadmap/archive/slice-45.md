## Slice 45: First Action-Intent Consumer Domain Controller (Destructibles)

**Status: complete (archived).** Depends on archive Slice 40 (action-intent
substrate). First pipeline-owned domain controller that consumes
`action_intents` into real gameplay.

Goal: prove the Slice 40 substrate end to end with destructible entity crates —
controller pattern, deferred structural commands, domain event, local nav
reaction via existing `entity_destroyed` path.

### What landed

- `Component.destructible` (14/32 tags) + dense `DestructibleStore`
  (`hit_points`, `destroy_on_interact`, `destroy_on_attack`); structural
  `set_destructible` / `EntityTemplate.destructible`; DataSystem set/get/const.
- Pipeline-owned `DestructibleController` at `action_react`:
  - Accepts `.interact` / `.attack` (flag-gated); ignores `.use` / `.signal`.
  - Target resolve: explicit alive destructible target, else cell-center/AABB
    scan on intent level (missing `world_level` → 0); lowest entity index then
    generation on ties.
  - Same-step multi-hit pending HP scratch sized to
    `action_intent_live_capacity`; net one `destroy_entity` or
    `set_destructible` per entity.
  - Preflights structural + event capacity before queue (dig pattern).
  - Emits scalar `destructible_destroyed` at `.domain_reaction` while entity
    still alive; commit emits `entity_destroyed` (nav local re-mask for static
    obstacles).
  - Optional soft-drop particle burst at body center; no SDL/audio handles.
- `stageContract(.action_react)` reads `{action_intents}`, writes
  `{structural_commands, events}`; multi-producer coexistence with
  `tier_policy` via `RangeOutputStream.appendRangeCounts`.
- Demo obstacles marked destructible (`hit_points = 1`); particles passed into
  pipeline update context; fixed event/structural headroom for destroys
  (`action_intent_live_capacity`, not map-scaled).
- Tests: store FailingAllocator, controller no-intent / cell destroy / multi-hit
  / flags / deterministic multi-candidate / payload purity / no dual-write
  NavigationIntent; pipeline stub tests replaced by real consumer counts.

### Checklist

- [x] Destructible `DataSystem` component (tag 14/32) + store + structural
      wiring.
- [x] Controller consumes action intents → deferred destruction commands;
      domain event; optional particles.
- [x] Capacity / determinism / payload-purity / NavigationIntent-untouched
      tests; Slice 40 stub consumer replaced.
- [x] Docs: `simulation-tiers-and-pipeline.md`, `architecture.md`.

### Acceptance checks

- [x] Action intent targeting a destructible destroys it deterministically
      through deferred commands; nav updates locally via `entity_destroyed`.
- [x] No action producers running → world unchanged.
- [x] `NavigationIntent` contract untouched; `zig build verify` passes.

