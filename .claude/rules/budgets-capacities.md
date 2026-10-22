---
paths:
  - "src/**/*.zig"
  - "docs/roadmap/**"
  - "docs/framework-implementation-slices.md"
---

# Budgets, Capacities, And Thresholds

- The unit of change owns its storage and work: for terrain and nav, the chunk.
  A level or world holds only a directory of its units; nothing is sized to a
  level's area or a world's extent. Everything lives per world instance
  (`engine-design.md` § Target scale): no global or cross-world caps or tables.
- A local change (one dig, ramp, or chunk) costs work proportional to what it
  changed, never to level size, depth, or world count. The one exception is
  reachability maintenance: after a removed connection it costs the smaller
  side when the removal splits a component, or the reach until both sides'
  floods meet when nothing splits (a cut ring costs its ring). While one-way
  links exist, a change to a one-way link or to a component holding one costs
  that one-way system's terminals and links plus the closure rows of its
  affected terminals.
- A level's size is fixed when it is created; depth and world count grow in
  play at the seam. Dig/build changes contents, never level size.
- Runtime-growing data (population, items, nodes, links, per-chunk storage)
  starts at content-derived size and grows at the named seam
  (`memory-performance.md`). Only allocator OOM fails growth, as an ordinary
  error leaving state intact for retry.
- Per-step and per-query work budgets are fixed counts, never milliseconds and
  never derived from world, map, cell, or portal count or any measured scale.
  Over-budget work defers deterministically and is tested as such; a
  chronically short budget gets deterministic deferral, a bounded retry
  ladder, or a better algorithm, never a bigger number for one map.
- No order, deferral, refusal, or result depends on reserved capacity. No dig,
  build, cave-in, or explosion is ever refused for capacity; a new limit or
  refusal is never a design tool.
- The only fixed caps are index/format widths (`u16`/`u32`, save layouts)
  proven unreachable for everything the world can grow to (growth paths
  included, not only initial sizes) and failing loudly when the world is
  created or loaded, and presentation-only pools no simulation reads
  (particles, text labels) with deterministic overflow drop. A pool's row
  index may be `u32` when exhausting it requires 2^32 live rows of that pool;
  exhaustion fails at the growth seam as `OutOfMemory`, never as a refusal or
  a distinct error.
- Platform resource checks (GPU bytes, nav memory) report; they never refuse a
  world, level, or terrain change, loaded or created in play, and never run
  per step.
- Heuristic thresholds derive from the cost of the operation they gate, never
  world size.
- Pick per structure as an engine programmer would: pools, free lists, and
  generational handles for churn; SoA contiguity over footprint.
- Changing a budget, capacity, or threshold, in either direction, states its
  benefit against hot-path cost, format churn, and determinism.
- Process-global state only where the OS passes no context (signal handlers,
  exception filters): module-level, fixed-size, and documented at the site.
