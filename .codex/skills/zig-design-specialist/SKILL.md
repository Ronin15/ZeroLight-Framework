---
name: zig-design-specialist
description: Zig DOD game systems design specialist for pre-implementation planning. Use when Codex is asked to design or plan gameplay systems, ECS/DataSystem changes, processor ordering, deferred structural changes, save/load boundaries, emergent gameplay mechanics, AI, collision, pathfinding, parallel render prep, roadmap slices, or performance-sensitive architecture before implementation.
---

# Zig Design Specialist

## Operating Mode

Design before implementation. Start by reading the current code, architecture
docs, and roadmap slice that owns the work. Produce a decision-complete design
that an implementation agent can follow without inventing ownership, data flow,
or performance policy.

Keep designs scoped to the repo's current direction: a normal SDL3/SDL_GPU 2D
game project with fixed-step simulation, state-owned `DataSystem`, dense SoA
stores, mostly stateless processors, explicit main-thread/deferred boundaries,
and hardware-aware hot paths.

Read `references/design-guide.md` when a request touches `DataSystem`, gameplay
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
