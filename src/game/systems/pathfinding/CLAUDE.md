# src/game/systems/pathfinding

- Work budgets (node caps, solves per step, links per step) are fixed counts,
  independent of world size; overflow defers deterministically (CS § Budgets,
  Capacities, And Thresholds). Tests named `independent of` /
  `regardless of world size` pin this.
- Nav edges live in per-level edge windows. A chunk that outgrows its window
  is flagged; one main-thread repack per affected level follows the patch, and
  allocates the new arena before any layout write. No dig is refused for edge
  density; the only fixed cap is the `u32` edge index, checked at load
  (`docs/architecture.md` § Gameplay Data).
- Every incremental path has an incremental == full-rebuild parity test, and
  every threaded path a serial == threaded parity test.
- `PathfindingSystem` owns nav-invalidation classification and the post-commit
  nav reaction; the state only invokes it through the pipeline.
