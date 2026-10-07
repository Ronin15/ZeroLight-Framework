## Slice 35: AI And Steering Hot-Loop SIMD Restructure

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 34](../archive/slice-34.md), [Slice 24](../archive/slice-24.md), [Slice 32](../archive/slice-32.md), [Slice 55](slice-55.md), [Slice 52D](slice-52d.md) (measure after 55; land after 52D) · Track: [Emergent AI](../tracks/emergent-ai.md)

Goal: restructure the existing scalar per-agent / per-neighbor loops in AI and
steering into packed-SoA-scratch vectorized kernels, so they hold up in heavy
scenes, large battles, and late-game worlds where they become the dominant cost.

Why deferred (not part of Slice 34): this is optimization, not foundation, and
its acceptance is defined at target scale. Prerequisites are landed: Slice 34
primitives, Slice 24 scoping (who reaches these loops per step), Slice 32's
arbitration reshape of AI decide, and Slice 33 archetypes / battle-scale demo
counts for representative load. New cognition stages stay SIMD-first per the
track contract; this slice targets the **pre-existing** AI separation /
decide-blend and steering avoidance scalar loops. Do not use 35 as a reason to
rewrite the utility/sticky arbitration contract.

Current foundation:

- AI separation accumulation and decision math (`systems/ai.zig`) and steering
  neighbor/obstacle avoidance (`systems/steering.zig`) are scalar today because of
  sparse-index gather and per-element early exits — a data-layout limitation, not
  an inherent one.
- Slice 34 supplies gather/rsqrt/normalize/sincos and the packed-SoA-scratch idiom.

Checklist:

- [ ] Restructure AI separation accumulation: gather each agent's in-range
      neighbors once into packed SoA scratch, vectorize the
      `dx, dy, dist2, inv_sqrt, accumulate` math, and replace the per-neighbor
      early exit with a bounded mask.
- [ ] Vectorize AI decision math (`decideDir`, wander/seek blend, normalize)
      across agents using `select`-masked branches instead of per-agent control
      flow.
- [ ] Restructure steering neighbor/obstacle avoidance: pack sampled neighbors and
      obstacle boxes into local SoA scratch, vectorize the
      distance/push/normalize/blend force math, and keep the dynamic sampling
      bound as a batched mask.
- [ ] Leave `max_separation_neighbors` (32) and `max_separation_candidate_checks`
      (128) fixed. Vectorize inside those caps.
- [ ] Size the packed gather scratch from those fixed per-query budgets, never
      from population or a warmed high-water mark: per agent, AI separation
      packs at most `max_separation_neighbors` rows, and steering packs at most
      `max_agent_candidate_checks` neighbor rows plus
      `max_obstacle_candidate_checks` obstacle rows. Each worker's range job
      therefore holds them as comptime-sized inline arrays (one agent at a
      time, no shared writable scratch, nothing to reserve). Across-agent
      decide/blend vectorization reads the existing SoA columns in place.
- [ ] **World-gate bench (ungated; the trigger instrument for the next item).**
      Add `src/benchmarks/world_gate.zig`, group `world-gate`, using
      `suite.eventScaleCounts` item counts and the standard case set. Its
      fixture (bench-file-only, never called from tests) holds N AI movement
      bodies on an underground level (level 1) whose tile grid alternates solid
      and walkable cells, so about half the bodies hit the gate each step, plus
      the player. Each iteration restores the pre-step positions, then runs
      `world_gate.apply`. Today only `serial-direct` measures anything (the gate
      is scalar and serial).
- [ ] **World-gate SIMD + threading (gated on the `world-gate` trigger).**
      Promoted from the former Scaling Gaps "World-gate SIMD" line. Trigger:
      `zig build bench -- --group world-gate --case serial-direct --items 10000`
      costs more than `zig build bench -- --group movement --case serial-direct
      --items 10000` (the stage that runs just before it, at the same body
      count, in the same ReleaseFast bench build). Until the trigger fires,
      `world_gate.apply` stays scalar. When it fires:
      - The NPC bounds clamp and NPC tile gate become one range job over the
        dense AI movement rows. Each row writes only its own position and
        velocity columns, so ranges are disjoint and need no shared output or
        reserve. The job keeps a serial fallback, has no static item-count
        floor, and opens with the dual `range.index` / write-range asserts.
        The player gate stays scalar (one body).
      - SIMD goes through `src/core/simd.zig` / `src/core/math.zig` only (no raw
        `@Vector` in `world_gate.zig`). The bounds clamp is a dense vector
        clamp. The tile gate packs each lane's four corner samples into packed
        scratch, vectorizes the cell-coordinate math, and gathers
        `levelBlocksMovement` per sample. Lanes on level 0, off-world samples,
        and non-movement tiers are masked, not branched. Per-range scratch is a
        comptime-sized inline array (nothing to reserve).
      - Tests: scalar-vs-SIMD parity and serial-vs-threaded parity on a real
        multi-worker `ThreadSystem`, both bit-identical in positions and
        velocities. Cover the edge epsilon, off-world cells, the level-0
        pass-through, skipped non-movement tiers, the x-then-y resolve order,
        and whatever the gate does when this lands (Slice 38's elevation
        reads, Slice 68B's knockback zeroing). Add a `FailingAllocator` proof
        that a serial step and a multi-worker step allocate nothing. Use a
        minimal fixture.
      - Acceptance: the `world-gate` bench shows a win at 10,000+ bodies and no
        regression at 1,024.

Acceptance checks:

- [ ] Each restructured path has scalar-vs-SIMD and serial-vs-threaded parity
      tests (bit-stable across layouts).
- [ ] `zig build bench` shows wins at high neighbor/agent counts measured at
      target battle scale, with no regression at low counts.
- [ ] The gather scratch is the comptime-sized inline arrays above (a capacity
      fixed by the per-query budgets, not by population), and a
      `std.testing.FailingAllocator` proof runs a serial and a real
      multi-worker AI + steering step after `reserve`, on a minimal fixture
      whose agents hit the full neighbor and candidate caps, with zero
      allocations.
- [ ] `max_separation_neighbors` is still 32 and `max_separation_candidate_checks`
      is still 128 after the restructure.
- [ ] Only irreducibly scalar loops inside this slice (pathfinding frontier
      traversal/portal linking, particle swap-remove) remain scalar, each
      documented with the reason per the coding-standards policy.
      `world_gate.apply` stays scalar until the `world-gate` trigger fires
      (Checklist item above). The bench item still lands with this slice.
- [ ] `zig build verify` passes.

