## Slice 35: AI And Steering Hot-Loop SIMD Restructure

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 52D](slice-52d.md) (archive [34](../archive/slice-34.md), [24](../archive/slice-24.md), [32](../archive/slice-32.md) landed) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Measure after Slice 55 and 52D land.

Goal: the scalar per-agent and per-neighbor loops in AI separation, AI
decision math, and steering avoidance become packed-scratch SIMD kernels, so
per-agent cognition and steering cost stays low at large populations in every
world, bit-identical across scalar/SIMD and serial/threaded paths. It also
lands `world_gate.apply` as a threaded SIMD range job with its serial path,
and the `world-gate` bench that measures it.

### Current foundation

- AI separation accumulation and `decideDir` (`src/game/systems/ai.zig`) and
  steering neighbor/obstacle avoidance (`src/game/systems/steering.zig`) are
  scalar: sparse-index gathers and per-element early exits.
- Fixed per-query budgets: `max_separation_neighbors` = 32 and
  `max_separation_candidate_checks` = 128 (`ai.zig`);
  `max_agent_candidate_checks` = 64 and `max_obstacle_candidate_checks` = 64
  (`steering.zig`).
- Gather, rsqrt, normalize, sincos, and the packed-SoA-scratch idiom exist in
  `src/core/simd.zig` and `src/core/math.zig` (archive Slice 34).
- `world_gate.apply` (`src/game/systems/world_gate.zig`) is scalar and serial;
  no `world-gate` bench exists.
- ReleaseSafe trend data at 2048 movers puts the avoidance batch near 0.40 ms
  ([Scaling Gaps](../scaling-gaps.md); diagnostic, not a perf claim).

### Architecture notes

- Restructures existing loops only; the utility/sticky arbitration contract
  stays (`.claude/rules/simulation.md` § AI and affect). It measures against
  the cognition structure 55 lands on (re-based on 73).
- Per-query budgets stay fixed counts; gather scratch is sized from them,
  never from population or a high-water mark, so per-range scratch needs no
  reserve (`.claude/rules/budgets-capacities.md`).
- Vector math goes through `core`; branches become masks; only irreducible
  loops stay scalar, each with its reason at the site
  (`.claude/rules/memory-performance.md` § SIMD and core math).
- Scalar equals SIMD and serial equals threaded, bit for bit
  (`.claude/rules/threading.md`, `.claude/rules/simulation.md` § Determinism).
- `world_gate.apply` ships serial and threaded paths in its first
  implementation (`.claude/rules/threading.md`): the NPC bounds clamp and
  tile gate become one threaded SIMD range job over AI movement rows; the
  player gate stays scalar.
- Composes with 55: 55 cuts the rows reaching decide and steering; 35 cuts
  the per-row math.

### Checklist

- [ ] AI separation: in-range neighbors gathered once into packed scratch,
      vectorized accumulate, a bounded mask instead of the per-neighbor early
      exit.
- [ ] AI decision math (`decideDir`, wander/seek blend, normalize) vectorized
      across agents with masked branches.
- [ ] Steering neighbor/obstacle avoidance: sampled neighbors and obstacle
      boxes packed into scratch, vectorized force math, the sampling bound as
      a mask.
- [ ] Gather scratch sized from the fixed per-query budgets.
- [ ] `world-gate` bench group (`src/benchmarks/world_gate.zig`): bodies on an
      underground level of alternating solid and walkable cells, standard case
      set, at least three body counts.
- [ ] `world_gate.apply` NPC clamp and tile gate as a threaded SIMD range
      job with its serial path, with scalar/SIMD and serial/threaded parity
      covering edge epsilon, off-world cells, level-0 pass-through,
      non-movement tiers, x-then-y resolve order, and any elevation (38) or
      knockback (68B) reads present then; `FailingAllocator` proof for serial
      and multi-worker steps.
- [ ] Tests: scalar/SIMD and serial/threaded parity per restructured path; a
      `FailingAllocator` proof over a real multi-worker AI + steering step
      with agents at the full neighbor and candidate caps.

### Acceptance checks

- [ ] Every parity test passes, bit-stable across layouts.
- [ ] `ai` and `steering` benches at three or more agent counts show the
      restructured paths winning at the large end and no regression at the
      small end (`.claude/rules/tests-benchmarks.md`); `world-gate` covers
      serial and threaded at the same body counts.
- [ ] Per-query budgets are unchanged and the warmed proofs allocate nothing.
- [ ] `zig build verify` passes.
