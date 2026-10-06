## Slice 26: Entity Faction And Classification Model

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: give entities a classification so perception and behavior can distinguish
threat / ally / neutral. No team or faction concept exists anywhere today; it is
a hard prerequisite for perception (Slice 29) and behavior arbitration
(Slice 32).

Current foundation:

- Entities are dense SoA with stable `EntityId` handles and component masks
  (`data_system.zig`); the component-store pattern is established (e.g.
  `AiAgentStore`).
- No faction, team, allegiance, or relationship data exists.

Checklist:

- [x] Add a `Faction` component (`src/game/faction.zig`): a small enum
      faction id per entity, following the full component-store pattern.
- [x] Add a fixed faction-relationship matrix (enum × enum → stance:
      hostile / neutral / friendly), const-evaluated, scalar/enum only, no
      per-frame allocation and no hash lookup on hot paths.
- [x] Expose a stance query usable from processor hot paths (`stance(a, b)`)
      that compiles to a table index, not a map lookup.
- [x] Add to `EntityTemplate` and demo spawns so actors can be tagged.

Acceptance checks:

- [x] Stance lookups are allocation-free and branch-light on hot paths.
- [x] Faction assignment round-trips through structural commands and survives
      entity destruction/reuse with generational correctness.
- [x] `zig build test` covers stance symmetry/asymmetry and template wiring.


