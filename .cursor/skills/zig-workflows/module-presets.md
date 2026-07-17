# Module review presets

Path prefix `src/game/systems/pathfinding/` unless noted.

Subagent prompts live in `.cursor/agents/zig-review-specialist.md` (mirrors
`.claude/agents/zig-review-specialist.md`). Before each review unit, read
`docs/coding-standards.md`, `docs/simulation-tiers-and-pipeline.md`, and
`docs/architecture.md`.

## pathfinder

Mirrors `.claude/workflows/pathfinder-review.js`.

### Per-unit (phase 1)

| Unit | Files | Focus |
|------|-------|-------|
| `system` | `system.zig` | Per-frame request scheduling, agent state, pipeline integration, hot-path allocation (~3200 lines) |
| `nav_graph` | `nav_graph.zig` | Graph construction/representation (~2170 lines) |
| `caches` | `caches.zig` | Path/result caching, invalidation coherency, lifetime (~800 lines) |
| `solve` | `solve.zig` | Core search/solve correctness, allocation discipline (~590 lines) |
| `nav_grid` | `nav_grid.zig` | Grid/walkability; tile-agnostic comments (cells by walkability, not grass/tree) |
| `types_and_memory` | `types.zig`, `nav_memory.zig` | Shared types/contracts, arena/memory management |
| `group_field_and_scratch` | `group_field.zig`, `scratch.zig` | Flow/group field and scratch buffers; reuse vs per-frame allocation |
| `facade_and_test_support` | `../pathfinding.zig`, `test_support.zig` | Public facade surface; no test-only constructs in production API |
| `benchmarks` | `src/benchmarks/pathfinding.zig`, `src/benchmarks/nav_update.zig` | Realistic paths, bench conventions |

### Cross-cut prompts (phase 2)

- **module-coherency** — cross-file invariants, coordinate spaces, request lifecycle
  (`system` → `solve`, `nav_graph`, `nav_grid`, `caches`).
- **module-cohesion** — file split, duplication, facade surface, boundary violations.
- **standards-and-hotpath** — post-warmup allocation, hot-path logging, naming, tests.

### Phase 3

Synthesize: merge severity-ordered report; drop spurious findings.

## best-practices-review

Mirrors `.claude/workflows/zig-best-practices-review.js`. Weight toward mechanizable /
generalizable best-practice issues, not one-off gameplay logic bugs.

### Per-unit (phase 1)

| Unit | Files |
|------|-------|
| `pathfinding-system` | `src/game/systems/pathfinding/system.zig` |
| `pathfinding-navgraph` | `src/game/systems/pathfinding/nav_graph.zig`, `nav_grid.zig` |
| `pathfinding-support` | `caches.zig`, `solve.zig`, `group_field.zig`, `scratch.zig`, `nav_memory.zig`, `types.zig` |
| `ai` | `src/game/systems/ai.zig`, `ai_memory.zig`, `src/game/ai_archetypes.zig` |
| `perception` | `src/game/systems/perception.zig`, `src/game/data_system/perception.zig` |
| `steering-arbitration` | `src/game/systems/steering.zig`, `arbitration.zig` |
| `collision` | `src/game/systems/collision.zig`, `collision_response.zig`, `spatial_index.zig` |
| `movement-particle-affect` | `movement.zig`, `particle.zig`, `affect.zig` |
| `data-system-core` | `src/game/data_system/system.zig`, `types.zig`, `structural.zig` |
| `world-system` | `src/game/world_system.zig` |
| `simulation-pipeline` | `simulation_pipeline.zig`, `simulation.zig`, `simulation_scope.zig`, `systems/simulation_scope.zig` |
| `thread-system` | `src/app/thread_system.zig` |
| `renderer-batch` | `src/render/renderer.zig`, `sprite_batch.zig` |
| `render-prep` | `src/game/render_prep.zig`, `src/render/text.zig`, `resources.zig` |
| `core-simd-math` | `src/core/simd.zig`, `math.zig`, `rng.zig` |

### Phase 2–3

Verify findings adversarially, then synthesize durable lint/agent/doc guidance plus ranked
one-off fixes. Do not duplicate existing `idiom-lint` rules or agent guidance already in
the specialist prompts.

## deep-correctness-review

Mirrors `.claude/workflows/zig-deep-correctness-review-pass.js`. Pass 3: behavioral
correctness beyond idiom/surface — concurrency, algorithms, SIMD parity, pipeline
determinism, resource lifetime, test gaps.

### Per-theme (phase 1)

| Unit | Files | Focus |
|------|-------|-------|
| `thread-pool-core` | `src/app/thread_system.zig` | Dispatch/claim/join, atomics, work-range races, barrier correctness |
| `threaded-processor-dispatch` | `movement.zig`, `steering.zig`, `collision.zig`, `particle.zig` | Disjoint write ranges, reserve-before-dispatch, serial-vs-threaded parity |
| `threaded-gather-processors` | `ai.zig`, `perception.zig`, `affect.zig`, `ai_memory.zig` | Gather-into-scratch, range partitioning, AI/perception correctness |
| `pathfinding-search-correctness` | `system.zig`, `solve.zig`, `nav_grid.zig`, `caches.zig`, `group_field.zig` | A* within fixed budget, cache coherence, graceful degradation |
| `nav-graph-invalidation` | `nav_graph.zig`, `nav_memory.zig` | Incremental-dig patch vs rebuild, portal/edge consistency |
| `pipeline-ordering-determinism` | `simulation_pipeline.zig`, `simulation.zig`, `simulation_scope.zig`, `systems/simulation_scope.zig`, `arbitration.zig`, `dig_controller.zig` | Stage contracts, deterministic structural commits, controller conflict policy |
| `simd-numerical-parity` | `src/core/simd.zig`, `math.zig`, `collision_response.zig`, `spatial_index.zig` | Scalar/SIMD equivalence, NaN/inf edge cases, determinism |
| `gpu-and-render-lifetime` | `renderer.zig`, `sprite_batch.zig`, `resources.zig`, `text.zig`, `render_prep.zig` | GPU resource pairing, swapchain fail paths, in-flight transfer safety |
| `data-lifetime-and-handles` | `data_system/system.zig`, `structural.zig`, `agents.zig`, `world_system.zig` | Generational handles, swap-remove, mask/column consistency |
| `anomalies-and-test-gaps` | repo-wide (grep) | TODO/FIXME/HACK outliers; highest-value untested load-bearing invariants |

### Phase 2–3

Adversarially verify each finding, then synthesize ranked bugs, test gaps, and net-new
durable guidance.
