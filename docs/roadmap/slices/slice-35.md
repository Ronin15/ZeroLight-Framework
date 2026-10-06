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

Acceptance checks:

- [ ] Each restructured path has scalar-vs-SIMD and serial-vs-threaded parity
      tests (bit-stable across layouts).
- [ ] `zig build bench` shows wins at high neighbor/agent counts measured at
      target battle scale, with no regression at low counts.
- [ ] Gather-into-SoA-scratch buffers are allocation-free after warmup and
      reserved up front.
- [ ] `max_separation_neighbors` is still 32 and `max_separation_candidate_checks`
      is still 128 after the restructure.
- [ ] Only irreducibly scalar loops inside this slice (pathfinding frontier
      traversal/portal linking, particle swap-remove) remain scalar, each
      documented with the reason per the coding-standards policy.
      `world_gate.apply` stays scalar; that follow-up is the World-gate SIMD
      Scaling Gap.
- [ ] `zig build verify` passes.

