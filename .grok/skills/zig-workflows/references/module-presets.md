# Module review presets

Bare names in the pathfinder section are under `src/game/systems/pathfinding/`.
Other sections use the path written in the cell.

Subagent prompts live in `.grok/agents/zig-review-specialist.md`. Before each
review unit, read `docs/architecture.md` and
`docs/simulation-tiers-and-pipeline.md`. Cite the `.grok/rules/` file a
finding breaks, and read that section. Paths below are repo-relative.

## pathfinder

Used by the `/pathfinder-review` skill.

### Per-unit (phase 1)

| Unit | Files | Focus |
|------|-------|-------|
| `system` | `system.zig` | Per-frame request scheduling, agent state, pipeline integration, hot-path allocation (~3200 lines) |
| `nav_graph` | `nav_graph.zig` | Graph construction/representation (~2170 lines) |
| `caches` | `caches.zig` | Path/result caching, invalidation coherency, lifetime (~800 lines) |
| `solve` | `solve.zig` | Core search/solve correctness, allocation discipline (~590 lines) |
| `nav_grid` | `nav_grid.zig` | Grid/walkability; tile-agnostic comments (cells by walkability, not grass/tree) |
| `types_and_memory` | `types.zig` | Shared types and contracts |
| `group_field_and_scratch` | `group_field.zig`, `scratch.zig` | Flow/group field and scratch buffers; reuse vs per-frame allocation |
| `facade_and_test_support` | `src/game/systems/pathfinding.zig`, `test_support.zig` | Public facade surface; no test-only constructs in production API |
| `benchmarks` | `src/benchmarks/pathfinding/`, `src/benchmarks/nav_update.zig` | Realistic paths, bench conventions |

### Cross-cut prompts (phase 2)

- **module-coherency** — cross-file invariants, coordinate spaces, request lifecycle
  (`system` → `solve`, `nav_graph`, `nav_grid`, `caches`).
- **module-cohesion** — file split, duplication, facade surface, boundary violations.
- **standards-and-hotpath** — post-warmup allocation, hot-path logging, naming, tests.

### Phase 3

Synthesize: merge severity-ordered report; drop spurious findings.

## best-practices-review

Used by the `/zig-best-practices-review` skill. Weight toward mechanizable /
generalizable best-practice issues, not one-off gameplay logic bugs.

### Per-unit (phase 1)

| Unit | Files |
|------|-------|
| `pathfinding-system` | `src/game/systems/pathfinding/system.zig` |
| `pathfinding-navgraph` | `src/game/systems/pathfinding/nav_graph.zig`, `src/game/systems/pathfinding/nav_grid.zig` |
| `pathfinding-support` | `src/game/systems/pathfinding/caches.zig`, `src/game/systems/pathfinding/solve.zig`, `src/game/systems/pathfinding/group_field.zig`, `src/game/systems/pathfinding/scratch.zig`, `src/game/systems/pathfinding/types.zig` |
| `ai` | `src/game/systems/ai.zig`, `src/game/systems/ai_memory.zig`, `src/game/ai_archetypes.zig` |
| `perception` | `src/game/systems/perception.zig`, `src/game/data_system/perception.zig` |
| `steering-arbitration` | `src/game/systems/steering/`, `src/game/systems/arbitration.zig` |
| `collision` | `src/game/systems/collision.zig`, `src/game/systems/collision_response.zig`, `src/game/systems/spatial_index.zig` |
| `movement-particle-affect` | `src/game/systems/movement.zig`, `src/game/systems/particle.zig`, `src/game/systems/affect.zig` |
| `data-system-core` | `src/game/data_system/system.zig`, `src/game/data_system/types.zig`, `src/game/data_system/structural.zig` |
| `world-system` | `src/game/world/system.zig` |
| `simulation-pipeline` | `src/game/simulation_pipeline.zig`, `src/game/simulation.zig`, `src/game/simulation_scope.zig`, `src/game/systems/simulation_scope.zig` |
| `thread-system` | `src/app/thread_system.zig` |
| `renderer-batch` | `src/render/renderer.zig`, `src/render/sprite_batch.zig` |
| `render-prep` | `src/game/render_prep.zig`, `src/render/text.zig`, `src/render/resources.zig` |
| `core-simd-math` | `src/core/simd.zig`, `src/core/math.zig`, `src/core/rng.zig` |

### Phase 2–3

Verify findings adversarially, then synthesize durable lint/agent/doc guidance plus ranked
one-off fixes. Do not duplicate existing `idiom-lint` rules or agent guidance already in
the specialist prompts.

## deep-correctness-review

Used by the `/zig-deep-correctness-review` skill. Pass 3: behavioral
correctness beyond idiom/surface — concurrency, algorithms, SIMD parity, pipeline
determinism, resource lifetime, test gaps.

### Per-theme (phase 1)

| Unit | Files | Focus |
|------|-------|-------|
| `thread-pool-core` | `src/app/thread_system.zig` | Dispatch/claim/join, atomics, work-range races, barrier correctness |
| `threaded-processor-dispatch` | `src/game/systems/movement.zig`, `src/game/systems/steering/`, `src/game/systems/collision.zig`, `src/game/systems/particle.zig` | Disjoint write ranges, reserve-before-dispatch, serial-vs-threaded parity |
| `threaded-gather-processors` | `src/game/systems/ai.zig`, `src/game/systems/perception.zig`, `src/game/systems/affect.zig`, `src/game/systems/ai_memory.zig` | Gather-into-scratch, range partitioning, AI/perception correctness |
| `pathfinding-search-correctness` | `src/game/systems/pathfinding/system.zig`, `src/game/systems/pathfinding/solve.zig`, `src/game/systems/pathfinding/nav_grid.zig`, `src/game/systems/pathfinding/caches.zig`, `src/game/systems/pathfinding/group_field.zig` | A* within fixed budget, cache coherence, graceful degradation |
| `nav-graph-invalidation` | `src/game/systems/pathfinding/nav_graph.zig` | Incremental-dig patch vs rebuild, portal/edge consistency |
| `pipeline-ordering-determinism` | `src/game/simulation_pipeline.zig`, `src/game/simulation.zig`, `src/game/simulation_scope.zig`, `src/game/systems/simulation_scope.zig`, `src/game/systems/arbitration.zig`, `src/game/dig_controller.zig` | Stage contracts, deterministic structural commits, controller conflict policy |
| `simd-numerical-parity` | `src/core/simd.zig`, `src/core/math.zig`, `src/game/systems/collision_response.zig`, `src/game/systems/spatial_index.zig` | Scalar/SIMD equivalence, NaN/inf edge cases, determinism |
| `gpu-and-render-lifetime` | `src/render/renderer.zig`, `src/render/sprite_batch.zig`, `src/render/resources.zig`, `src/render/text.zig`, `src/game/render_prep.zig` | GPU resource pairing, swapchain fail paths, in-flight transfer safety |
| `data-lifetime-and-handles` | `src/game/data_system/system.zig`, `src/game/data_system/structural.zig`, `src/game/data_system/agents.zig`, `src/game/world/system.zig` | Generational handles, swap-remove, mask/column consistency |
| `anomalies-and-test-gaps` | repo-wide (grep) | TODO/FIXME/HACK outliers; highest-value untested load-bearing invariants |

### Phase 2–3

Adversarially verify each finding, then synthesize ranked bugs, test gaps, and net-new
durable guidance.
