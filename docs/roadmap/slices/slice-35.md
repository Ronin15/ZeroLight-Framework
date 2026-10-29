## Slice 35: AI Decision Math And World-Gate SIMD Restructure

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 52D](slice-52d.md) (archive [34](../archive/slice-34.md), [24](../archive/slice-24.md), [32](../archive/slice-32.md) landed) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: in progress.** The `world_gate` threaded item landed (`f0adc9a`) on
the core branch; its whole-file cost-model check stays open. The AI decision
math is not started: measure after Slice 55 and 52D land.

Goal: AI decision math (`decideDir`, wander/seek blend, normalize) runs as
SIMD kernels across agents, so per-agent cognition cost stays low at large
populations in every world, bit-identical across scalar/SIMD and
serial/threaded paths. It also lands `world_gate.apply` as a threaded SIMD
range job with its serial path, and the `world-gate` bench that measures it.
AI separation's accumulate is [84](../archive/slice-84.md)'s and steering's agent
avoidance [85](../archive/slice-85.md)'s.

### Current foundation

- `decideDir` (`src/game/systems/ai.zig:831` at HEAD) is scalar.
- Gather, rsqrt, normalize, sincos, and the packed-SoA-scratch idiom exist in
  `src/core/simd.zig` and `src/core/math.zig` (archive Slice 34).
- `WorldGateSystem.apply` (`src/game/systems/world_gate.zig`, staged at
  `simulation_pipeline.zig:1894`) dispatches `gateJob` (`world_gate.zig:207`)
  over the movement rows under the system's tuner: the bounds clamp and tile
  gate as lane batches on the collision bounds (mirrored into movement-row
  columns by `DataSystem`), then the player row on main
  (`docs/architecture.md` § Source Layout).
- Measured before the landing (Debug, `5d5a089`, scalar walks on main):
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
      (`5d5a089`); its threaded cases joined with the threaded gate below.
- [x] `world_gate.apply` NPC clamp and tile gate as a threaded SIMD range
      job with its serial path (`f0adc9a`). Parity and allocation proofs:
      `world_gate.zig:456`, `:497`, `:530`, `:604`; the bench has uniform and
      interleaved shapes with a dispatch check. Measured (Debug, census):
      16,384 tuned step 5.13 to 3.60 ms, clamp main 1.84 ms to 2.8 us. Failure scenario: main time grows with every
      AI body in the world each step. Pass (group doc): linear in bodies,
      dispatched across workers with a SIMD tile test, `world-gate` gaining
      the threaded cases. Scalar/SIMD and serial/threaded parity
      covering the 0.5-unit edge-sample inset, off-world cells, level-0 pass-through,
      non-movement tiers, x-then-y resolve order, and any elevation (38) or
      knockback (68B) reads present then; `FailingAllocator` proof for serial
      and multi-worker steps.
- [ ] The whole of `systems/world_gate.zig` checked against the cost model and
      the rules (owner 2026-10-16), not only the items above. Each finding
      becomes an item here. Findings so far:
      - Row order: moved to slice 89's world-gate item (measure first; a
        per-row terrain read at the row's position is an exempt point lookup,
        owner 2026-10-24, `.grok/rules/memory-performance.md` § Data-oriented
        design). Failure kept for reference: `gateRange` (`world_gate.zig:248`) walks the
        movement rows in store order and resolves each lane's terrain cell with
        a data-dependent address (`blockedLanes`, `:317`), so work is not
        grouped by the chunk `(level, cx, cy)` it reads; the `interleaved`
        `world-gate` shape (non-AI, dormant, and gated rows across two levels)
        costs per row what the uniform shape does, about 2x per gated row.
        Pass: slice 89's item.
      - Tuned versus fixed controls: moved to slice 89's tuner item (owner
        2026-10-24; the measured cause points at the nudge).
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
