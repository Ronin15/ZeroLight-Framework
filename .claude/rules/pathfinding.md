---
paths:
  - "src/game/systems/pathfinding/**"
  - "src/game/systems/pathfinding.zig"
  - "src/benchmarks/pathfinding/**"
  - "src/benchmarks/nav_size.zig"
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
- Cache and pending keys are goal-keyed: nav version, agent class, goal
  level, and goal cell.
- Reachability is maintained at every nav batch as connectivity IDs plus a
  one-way reach closure, and answered in O(1) at intake, status, and solve.
  It is never cached and never discovered by a failed search. `unavailable`
  means start and goal are unreachable or no open goal cell lies within the
  projection radius. An exhausted budget is never `unavailable`: it defers
  deterministically and never returns a partial path as complete.
- `PathfindingSystem` owns the post-commit nav reaction end to end.
- Re-derive touched chunks whole from the world; the dirty buffer grows, never
  drops.
- Graph node ids are internal: they never persist across steps and are never
  cache or pending keys; caches and results hold cells, so a patch may lay out
  the chunks it touches freely.
- Connectivity IDs are internal to the graph: they change only in nav batches
  and are never cache, pending, or save keys.
- A local nav change never invalidates cached results world-wide; a version
  bump is reserved for changes that can invalidate every result.
- Identical link sets yield identical layouts in incremental and full builds;
  links are append-only.
- Level changes commit only by plane traversal against world geometry, never by
  a path-view field.
