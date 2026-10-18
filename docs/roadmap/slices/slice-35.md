## Slice 35: AI Decision Math And World-Gate SIMD Restructure

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 52D](slice-52d.md) (archive [34](../archive/slice-34.md), [24](../archive/slice-24.md), [32](../archive/slice-32.md) landed) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Measure after Slice 55 and 52D land. The
`world_gate` items land first, on the core branch (Engine-Core Overhaul
order), independent of 55 and 52D; the `world-gate` bench landed there.

Goal: AI decision math (`decideDir`, wander/seek blend, normalize) runs as
SIMD kernels across agents, so per-agent cognition cost stays low at large
populations in every world, bit-identical across scalar/SIMD and
serial/threaded paths. It also lands `world_gate.apply` as a threaded SIMD
range job with its serial path, and the `world-gate` bench that measures it.
AI separation's accumulate is [84](../archive/slice-84.md)'s and steering's agent
avoidance [85](slice-85.md)'s.

### Current foundation

- `decideDir` (`src/game/systems/ai.zig:788` at HEAD) is scalar.
- Gather, rsqrt, normalize, sincos, and the packed-SoA-scratch idiom exist in
  `src/core/simd.zig` and `src/core/math.zig` (archive Slice 34).
- `world_gate.apply` (`src/game/systems/world_gate.zig`, staged at
  `simulation_pipeline.zig:1566`) runs two scalar population walks on main,
  `gateNpcEntitiesToWalkableTiles` (`world_gate.zig:36`) and
  `clampAiEntitiesToBounds` (`world_gate.zig:114`), with no threaded path.
- Measured (Debug, `5d5a089`):
  - `world-gate`, serial: 1.48 / 5.88 / 17.19 ms at 4,096 / 16,384 / 65,536
    bodies (linear).
  - `production-step` tuned, spread P 16,384: `clamp_bounds` 1.92 ms, all on
    main, about a fifth of a 9.8 ms step.

### Architecture notes

- Restructures existing loops only; the utility/sticky arbitration contract
  stays (`.grok/rules/simulation.md` § AI and affect). It measures against
  the cognition structure 55 lands on (re-based on 73).
- Vector math goes through `core`; branches become masks; only irreducible
  loops stay scalar, each with its reason at the site
  (`.grok/rules/memory-performance.md` § SIMD and core math).
- Scalar equals SIMD and serial equals threaded, bit for bit
  (`.grok/rules/threading.md`, `.grok/rules/simulation.md` § Determinism).
- `world_gate.apply` ships serial and threaded paths in its first
  implementation (`.grok/rules/threading.md`): the NPC bounds clamp and
  tile gate become one threaded SIMD range job over AI movement rows; the
  player gate stays scalar.
- Composes with 55: 55 cuts the rows reaching decide; 35 cuts
  the per-row math.

### Checklist

- [ ] AI decision math (`decideDir`, wander/seek blend, normalize) vectorized
      across agents with masked branches.
- [x] `world-gate` bench group: serial baseline at three body counts
      (`5d5a089`); its threaded cases join the threaded gate below.
- [ ] `world_gate.apply` NPC clamp and tile gate as a threaded SIMD range
      job with its serial path. Failure scenario: main time grows with every
      AI body in the world each step. Pass (group doc): linear in bodies,
      dispatched across workers with a SIMD tile test, `world-gate` gaining
      the threaded cases. Scalar/SIMD and serial/threaded parity
      covering the 0.5-unit edge-sample inset, off-world cells, level-0 pass-through,
      non-movement tiers, x-then-y resolve order, and any elevation (38) or
      knockback (68B) reads present then; `FailingAllocator` proof for serial
      and multi-worker steps.
- [ ] The whole of `systems/world_gate.zig` checked against the cost model and
      the rules (owner 2026-10-16), not only the items above. Each finding
      becomes an item here.
- [ ] Tests: scalar/SIMD and serial/threaded parity per restructured path.

### Acceptance checks

- [ ] Every parity test passes, bit-stable across layouts.
- [ ] The `ai` bench at three or more agent counts shows no regression beyond
      run-to-run spread (`.grok/rules/tests-benchmarks.md`); a SIMD gain
      claim comes only from the targeted ReleaseFast run
      (`.grok/rules/build-validation.md`); `world-gate` covers serial and
      threaded at the same body counts.
- [ ] The warmed proofs allocate nothing.
- [ ] `zig build verify` passes.
