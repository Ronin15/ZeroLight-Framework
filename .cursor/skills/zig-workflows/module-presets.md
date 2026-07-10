# Module review presets

Path prefix `src/game/systems/pathfinding/` unless noted.

## pathfinder

### Per-unit (phase 1)

| Unit | Files | Focus |
|------|-------|-------|
| `system` | `system.zig` | Per-frame scheduling, agent state, pipeline integration, hot-path allocation |
| `nav_graph` | `nav_graph.zig` | Graph construction/representation |
| `caches` | `caches.zig` | Path/result caching, invalidation, lifetime |
| `solve` | `solve.zig` | Search/solve correctness, allocation discipline |
| `nav_grid` | `nav_grid.zig` | Grid/walkability; tile-agnostic comments |
| `types_and_memory` | `types.zig`, `nav_memory.zig` | Shared contracts, arena/memory |
| `group_field_and_scratch` | `group_field.zig`, `scratch.zig` | Scratch reuse vs per-frame allocation |
| `facade_and_test_support` | `pathfinding.zig`, `test_support.zig` | Public surface; no test leaks into production API |
| `benchmarks` | `src/benchmarks/pathfinding.zig`, `src/benchmarks/nav_update.zig` | Realistic paths, bench conventions |

### Cross-cut prompts (phase 2)

- **module-coherency** — cross-file invariants, coordinate spaces, request lifecycle
  (`system` → `solve`, `nav_graph`, `nav_grid`, `caches`).
- **module-cohesion** — file split, duplication, facade surface, boundary violations.
- **standards-and-hotpath** — post-warmup allocation, hot-path logging, naming, tests.
