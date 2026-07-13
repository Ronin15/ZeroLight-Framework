---
name: architecture-assessment
description: >-
  Assess ZeroLight-Framework architecture for scalable emergent gameplay
  simulation. Use when the user asks how ready the engine is for emergent
  gameplay, architecture assessment, extensibility review, or runs
  /architecture-assessment.
---

# Architecture Assessment

Multi-phase read-only assessment. Parent spawns all subagents (depth limit 1).
Prefer `zig-design-specialist` for analysis units; synthesis may be parent or one
final design specialist.

## Phase 1 — Docs scan (parallel)

Spawn four `zig-design-specialist` agents (`capability_mode: read-only`,
`background: true`):

| Label | Read | Focus |
|-------|------|--------|
| `docs:arch+sim` | `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md` | Layout, ownership, frame flow, pipeline/tiers, threading, adding systems |
| `docs:state+standards` | `docs/state-stack-and-input.md`, `docs/coding-standards.md` | State/input contracts, DOD/SoA/SIMD/alloc rules |
| `docs:roadmap` | `docs/framework-implementation-slices.md` (+ archive if needed) | Settled vs frontier slices, planned emergent capabilities, gaps |
| `docs:render+assets` | `docs/rendering-assets-shaders.md`, `docs/atlas-asset-workflow.md` | Sim/render boundary, stable IDs, scale with entity variety |

Each unit returns: area, summary, strengths, weaknesses, gaps, key_facts.

## Phase 2 — Code scan (parallel)

Spawn five `zig-design-specialist` agents after listing live paths under
`src/game/` (files may have moved — resolve via list/grep first):

| Label | Areas | Focus |
|-------|--------|--------|
| `code:data+pipeline` | `data_system*`, `simulation_pipeline.zig`, simulation scope | SoA, processor order, extensibility, data deps |
| `code:systems` | `systems/` movement, ai, collision, steering, … | Access patterns, shared-state safety, SIMD, slotting new systems |
| `code:engine+threads` | `src/app/engine.zig`, `thread_system.zig`, `time_loop.zig` | Fixed-step drive, pool, parallel phases, limits |
| `code:world+pathfinding` | `world_system.zig`, `systems/pathfinding/` | World model, dynamic nav, spatial queries |
| `code:controllers` | `render_prep.zig`, dig/audio controllers | Controllers, deferred structural changes, sim/render split |

Each unit returns: module, summary, data_layout, concurrency_model,
extensibility_notes, bottlenecks, emergent_readiness, key_facts.

## Phase 3 — Synthesis

One synthesis pass (parent or `zig-design-specialist`) over all findings.
Produce a Markdown report:

1. **Executive summary** — readiness /10, key strengths, critical gaps
2. **Architecture strengths** for emergent gameplay (with evidence)
3. **Critical gaps and risks** — High / Medium / Low
4. **Scalability** — entity scale, system interaction, threading, world dynamism
5. **Readiness by domain** — AI, collision/spatial, dynamic world, multi-agent, events/reactions
6. **Recommended next steps** — ordered by impact
7. **Risk register** — top 5 with mitigations

## Done criteria

- Docs and code phases completed
- Single assessment report delivered; no code edits
