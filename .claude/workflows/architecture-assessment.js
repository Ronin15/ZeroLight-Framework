
export const meta = {
  name: 'architecture-assessment',
  description: 'Assess ZeroLight-Framework architecture for scalable emergent gameplay simulation',
  phases: [
    { title: 'Docs Scan', detail: 'Read canonical docs for architecture, simulation, state/input, roadmap' },
    { title: 'Code Scan', detail: 'Read key source modules: engine, data_system, simulation, systems' },
    { title: 'Synthesis', detail: 'Cross-reference findings into a structured assessment report' },
  ],
}

const DOCS_SCHEMA = {
  type: 'object',
  properties: {
    area: { type: 'string' },
    summary: { type: 'string' },
    strengths: { type: 'array', items: { type: 'string' } },
    weaknesses: { type: 'array', items: { type: 'string' } },
    gaps: { type: 'array', items: { type: 'string' } },
    key_facts: { type: 'array', items: { type: 'string' } },
  },
  required: ['area', 'summary', 'strengths', 'weaknesses', 'gaps', 'key_facts'],
}

const CODE_SCHEMA = {
  type: 'object',
  properties: {
    module: { type: 'string' },
    summary: { type: 'string' },
    data_layout: { type: 'string' },
    concurrency_model: { type: 'string' },
    extensibility_notes: { type: 'string' },
    bottlenecks: { type: 'array', items: { type: 'string' } },
    emergent_readiness: { type: 'string' },
    key_facts: { type: 'array', items: { type: 'string' } },
  },
  required: ['module', 'summary', 'data_layout', 'concurrency_model', 'extensibility_notes', 'bottlenecks', 'emergent_readiness', 'key_facts'],
}

phase('Docs Scan')

const docResults = await parallel([
  () => agent(
    `Read and analyze /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/architecture.md and /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/simulation-tiers-and-pipeline.md.
    Focus on: overall source layout, ownership model, frame flow, simulation pipeline contracts, tier structure, fixed-step loop, threading model, and how well the architecture supports adding new emergent gameplay systems.
    Return a structured analysis.`,
    { label: 'docs:arch+sim', phase: 'Docs Scan', schema: DOCS_SCHEMA }
  ),
  () => agent(
    `Read and analyze /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/state-stack-and-input.md and /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/coding-standards.md.
    Focus on: state stack contracts, transitions, input routing policy, performance constraints, coding standards for DOD patterns, SoA usage, SIMD policy, allocation rules, and how these constrain or enable emergent gameplay.
    Return a structured analysis.`,
    { label: 'docs:state+standards', phase: 'Docs Scan', schema: DOCS_SCHEMA }
  ),
  () => agent(
    `Read and analyze /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/framework-implementation-slices.md.
    Focus on: what slices are complete (settled), what is the current frontier (Slice 8 hardening), what future slices are planned (18+), what emergent gameplay capabilities are explicitly planned vs gaps, and the priority/ordering rationale.
    Return a structured analysis.`,
    { label: 'docs:roadmap', phase: 'Docs Scan', schema: DOCS_SCHEMA }
  ),
  () => agent(
    `Read and analyze /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/rendering-assets-shaders.md and /Users/roninxv/projects/zig_projects/ZeroLight-Framework/docs/atlas-asset-workflow.md.
    Focus on: how rendering and assets are decoupled from simulation, stable asset ID approach, render_prep pipeline boundary, whether the rendering architecture scales with many entity types, and constraints it imposes on gameplay variety.
    Return a structured analysis.`,
    { label: 'docs:render+assets', phase: 'Docs Scan', schema: DOCS_SCHEMA }
  ),
])

phase('Code Scan')

const codeResults = await parallel([
  () => agent(
    `Read these files and analyze the core simulation pipeline:
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/data_system.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/simulation_pipeline.zig (if exists, else check src/game/ for pipeline-related files)
    Run: ls /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/ to see all files first.
    Focus on: SoA data layout, entity capacity, how processors are registered/ordered, whether new systems can be added without modifying the pipeline core, data dependencies between systems, and readiness for many interacting simulation layers.`,
    { label: 'code:data+pipeline', phase: 'Code Scan', schema: CODE_SCHEMA }
  ),
  () => agent(
    `Read these files:
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/systems/movement.zig (or similar in src/game/systems/)
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/systems/ai.zig (or similar)
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/systems/collision.zig (or similar)
    Run: ls /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/systems/ first to see available systems.
    Focus on: per-system data access patterns, how they interact with the SoA store, whether they read/write shared state safely, SIMD usage, and how a new emergent system (e.g. resource spreading, fire propagation, crowd behavior) would slot in.`,
    { label: 'code:systems', phase: 'Code Scan', schema: CODE_SCHEMA }
  ),
  () => agent(
    `Read these files:
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/app/engine.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/app/thread_system.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/app/time_loop.zig
    Focus on: how the engine initializes and drives the fixed-step loop, thread pool setup and job dispatch, whether the threading model supports parallel simulation phases, and scalability limits (max threads, queue depth, job granularity).`,
    { label: 'code:engine+threads', phase: 'Code Scan', schema: CODE_SCHEMA }
  ),
  () => agent(
    `Read these files related to pathfinding and world systems:
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/world_system.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/pathfinding.zig (or src/game/systems/pathfinding/)
    Run: ls /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/systems/pathfinding/ first if it exists.
    Focus on: world/map data model, how navigation mesh or grid is managed, whether the world model supports dynamic changes (terrain modification, destructibles), how spatial queries are done, and readiness for emergent world-state gameplay.`,
    { label: 'code:world+pathfinding', phase: 'Code Scan', schema: CODE_SCHEMA }
  ),
  () => agent(
    `Read these files:
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/render_prep.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/dig_controller.zig
    - /Users/roninxv/projects/zig_projects/ZeroLight-Framework/src/game/audio_controller.zig
    Focus on: how render_prep decouples simulation from rendering, controller pattern for cross-cutting concerns, whether new controllers (e.g. particle events, status effects, emergent audio) can be added cleanly, and the deferred structural change model.`,
    { label: 'code:controllers', phase: 'Code Scan', schema: CODE_SCHEMA }
  ),
])

phase('Synthesis')

const allFindings = {
  docs: docResults.filter(Boolean),
  code: codeResults.filter(Boolean),
}

const report = await agent(
  `You are a senior game engine architect. Synthesize the following architectural analysis findings into a comprehensive assessment report for the ZeroLight-Framework.

CONTEXT: ZeroLight-Framework is a 2D game engine built on Zig 0.16 + SDL3/SDL_GPU. The goal is to assess how well the architecture supports a scalable, emergent gameplay simulation framework — meaning: multiple interacting simulation layers, complex AI behaviors, dynamic world state, and gameplay that arises from system interactions rather than scripted events.

DOC ANALYSIS FINDINGS:
${JSON.stringify(allFindings.docs, null, 2)}

CODE ANALYSIS FINDINGS:
${JSON.stringify(allFindings.code, null, 2)}

Write a structured assessment report covering:

1. **Executive Summary** (3-4 sentences: overall readiness score out of 10, key strengths, critical gaps)

2. **Architecture Strengths for Emergent Gameplay** (what's well-designed, with specific evidence)

3. **Critical Gaps and Risks** (what's missing or fragile, severity: High/Medium/Low)

4. **Scalability Analysis**
   - Entity/data scale ceiling
   - System interaction model scalability
   - Threading/parallelism headroom
   - World state dynamism

5. **Emergent Gameplay Readiness by Domain**
   - AI & Behavior Trees
   - Physics / Collision / Spatial Queries
   - Dynamic World State (terrain, destructibles, spreading effects)
   - Multi-agent coordination (flocking, group AI, resource competition)
   - Event/reaction systems (emergent audio, particles, status effects)

6. **Recommended Next Steps** (ordered by impact, with rationale)

7. **Risk Register** (top 5 architectural risks with mitigation paths)

Return the full report as plain markdown text.`,
  { label: 'synthesis:report', phase: 'Synthesis' }
)

return report
