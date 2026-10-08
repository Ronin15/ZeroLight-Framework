---
paths:
  - "src/game/systems/pathfinding/**"
  - "src/game/systems/pathfinding.zig"
  - "src/benchmarks/pathfinding.zig"
  - "src/benchmarks/nav_update.zig"
---

# Pathfinding And Nav

How it works: `docs/architecture.md` (pathfinding sections).

- Nav is processed per chunk so threading scales with any number of requests:
  updates fan out over dirty chunks, requests over request ranges against the
  read-only graph, and a request's work and scratch follow the chunks it
  touches, never level cells.
- The per-step request budget is a fixed count, independent of worker count;
  requests past it defer deterministically.
- Path results are consumed on later steps and never stall same-step movement.
- Cache and pending keys are goal-keyed (`nav_version`, `agent_class`,
  `goal_level`, `goal_cell`).
- Never negative-cache a budget exhaustion; `unavailable` means a definitive
  negative only. An exhausted budget defers deterministically, never returning
  a partial path as complete.
- `PathfindingSystem` owns the post-commit nav reaction end to end.
- Re-derive touched chunks whole from the world; the dirty buffer grows, never
  drops.
- Graph node ids are internal: they never persist across steps and are never
  cache or pending keys; caches and results hold cells, so a patch may lay out
  the chunks it touches freely.
- A local nav change never invalidates cached results world-wide; a version
  bump is reserved for changes that can invalidate every result.
- Identical link sets yield identical layouts in incremental and full builds;
  links are append-only.
- Level changes commit only by plane traversal against world geometry, never by
  a path-view field.
