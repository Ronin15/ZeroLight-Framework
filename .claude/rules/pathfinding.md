---
paths:
  - "src/game/systems/pathfinding/**"
  - "src/game/systems/pathfinding.zig"
  - "src/benchmarks/pathfinding.zig"
  - "src/benchmarks/nav_update.zig"
---

# Pathfinding And Nav

How it works: `docs/architecture.md` (pathfinding sections).

- Path results are consumed on later steps and never stall same-step movement.
- Cache and pending keys are goal-keyed (`nav_version`, `agent_class`,
  `goal_level`, `goal_cell`).
- Never negative-cache a budget exhaustion; `unavailable` means a definitive
  negative only. An exhausted budget defers deterministically, never returning
  a partial path as complete.
- `PathfindingSystem` owns the post-commit nav reaction end to end.
- Re-derive touched chunks whole from the world; the dirty buffer grows, never
  drops.
- Incremental patches keep `nav_version` stable and never renumber slots; only
  a full relabel bumps it. Slot ids never persist across steps; caches hold
  cells.
- Identical link sets yield identical layouts in incremental and full builds;
  links are append-only.
- Level changes commit only by plane traversal against world geometry, never by
  a path-view field.
