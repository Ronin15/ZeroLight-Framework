# Budgets, Capacities, And Thresholds

- The unit of change owns its storage and work: for terrain and nav, the chunk.
  A level or world holds only a directory of its units; nothing is sized to a
  level's area or a world's extent.
- A local change (one dig, ramp, or chunk) costs work proportional to what it
  changed, never to level size, depth, or world count.
- Everything lives per world instance; no global or cross-world caps or tables.
  Worlds, levels, and dungeons are created and released in play, and their
  memory goes with them.
- A level's size is fixed when it is created; depth and world count grow in
  play at the seam. Dig/build changes contents, never level size.
- Runtime-growing data (population, items, nodes, links, per-chunk storage)
  starts at content-derived size and grows at the named seam
  (`memory-performance.md`); only allocator OOM fails growth, as an ordinary
  error leaving state intact for retry.
- Per-step and per-query work budgets are fixed counts, never milliseconds and
  never derived from world, map, cell, or portal count or any measured scale.
- Over-budget work defers deterministically and is tested as such. A
  chronically short budget gets deterministic deferral, a bounded retry ladder,
  or a better algorithm, never a bigger number for one map.
- No order, deferral, refusal, or result depends on reserved capacity. No dig,
  build, cave-in, or explosion is ever refused for capacity; a new limit or
  refusal is never a design tool.
- The only fixed caps are index/format widths (`u16`/`u32`, save/replay
  layouts) proven unreachable for the loaded world and failing loudly at load,
  and presentation-only pools no simulation reads (particles, text labels) with
  deterministic overflow drop.
- Load-time platform checks (GPU byte budget, nav memory) run once at load,
  never during play.
- Heuristic thresholds derive from the cost of the operation they gate, never
  world size.
- Pick per structure as an engine programmer would: pools, free lists, and
  generational handles for churn; SoA contiguity over footprint.
- Changing a budget, capacity, or threshold, in either direction, states its
  benefit against hot-path cost, format churn, and determinism.
- Process-global state only where the OS passes no context (signal handlers,
  exception filters): module-level, fixed-size, and documented at the site.
