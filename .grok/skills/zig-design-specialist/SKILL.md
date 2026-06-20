---
name: zig-design-specialist
description: >
  Zig DOD game systems design specialist for ZeroLight-Framework pre-implementation
  planning. Use proactively in this repo before building new systems, changing
  architecture, ECS/DataSystem layout, processor order, SimulationPipeline shape,
  roadmap slices, or emergent gameplay mechanics. Triggers: design, plan, architect,
  how should we, approach, slice, roadmap, system design. Also use for
  /zig-design-specialist.
when-to-use: >
  Use proactively in ZeroLight-Framework before implementing new systems,
  architecture changes, ECS/DataSystem changes, processor contracts, deferred
  structural boundaries, save/load design, AI/collision/pathfinding/render-prep
  planning, SimulationPipeline/controller placement, roadmap slices, or any
  performance-sensitive emergent gameplay feature. Run this before zig-specialist
  when scope is unclear or crosses ownership boundaries. Produce ownership
  boundaries, data layouts, processor order, and acceptance criteria. Triggers:
  design, plan, architect, approach, strategy, slice, roadmap, system design, how
  should we, what is the right way. Slash: /zig-design-specialist.
metadata:
  short-description: "Plan DOD Zig game systems before implementation"
---

# Zig Design Specialist

## References

This skill has a companion detailed guide. At the start of any task that mentions the reference, resolve its location from the skill file itself:

1. The conversation/system context supplies the absolute filesystem path to this `SKILL.md`.
2. Compute the directory containing this file.
3. Read the guide with the `read_file` tool using the full path:
   `<that-directory>/references/design-guide.md`

## Operating Mode

Design before implementation. Start by reading the current code, architecture
docs, and roadmap slice that owns the work. Produce a decision-complete design
that an implementation agent can follow without inventing ownership, data flow,
or performance policy.

Keep designs scoped to the repo's current direction: a normal SDL3/SDL_GPU 2D
game project with fixed-step simulation, state-owned `DataSystem`, dense SoA
stores, mostly stateless processors, explicit main-thread/deferred boundaries,
and hardware-aware hot paths.

Read the reference guide (see the References section above) when a request touches `DataSystem`, gameplay
processors, emergent simulation, AI, collision, pathfinding, render prep,
save/load, or roadmap-slice design.

## Design Workflow

1. Ground the design in live files: owner modules, adjacent tests, architecture
   docs, and `docs/framework-implementation-slices.md`.
2. State the goal, success criteria, in-scope behavior, out-of-scope behavior,
   and the slice or subsystem that owns the work.
3. Define data ownership: persistent `DataSystem` storage, transient state-owned
   effects, renderer/resource handles, app services, and save/load boundaries.
4. Define processor flow: inputs, outputs, deterministic order, serial fallback,
   thread/SIMD shape, worker range ownership, and merge/deferred command points.
5. Define performance contracts: hot SoA columns, cache-line alignment,
   allocation policy, lookup policy, logging policy, and validation strategy.
6. Produce a compact implementation plan or roadmap patch with tests and
   acceptance checks. Do not mark a slice complete until runtime behavior, docs,
   tests, and acceptance are integrated.

## Required Design Outputs

- Ownership boundaries and exact owner layer.
- Frame/state call flow, preserving `main.zig` -> `Engine` phase method ->
  `StateStack` policy dispatch -> eligible state or states.
- Pipeline/controller placement when orchestration is shared or complex:
  state-owned pipeline, state-owned feature controllers, or plain state code.
- Data layout and lifetime for every persistent and transient data set.
- Ordered processor list, including what each processor reads and writes.
- Deferred/main-thread boundary for structural changes, SDL/GPU calls, asset
  loading, save/load streaming, and renderer resource ownership.
- Threading/SIMD policy, including serial fallback and range-safety constraints.
- Diagnostics and tests that prove behavior without requiring a display unless
  the feature is specifically GPU/display-gated.

## Coordination

Use `zig-specialist` after the design is accepted and the user asks for
implementation. Use `zig-review-specialist` for completed diffs. Use
`zig-debug-specialist` when design assumptions depend on reproducing a build,
test, runtime, asset, SDL, GPU, or performance failure.

Keep plans concise. Avoid long philosophy, package/library framing, and broad
future promises that are not tied to a slice, owner, and acceptance check.